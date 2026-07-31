import ComposableArchitecture
import Foundation
import Testing
import LoomSharedModels
@testable import AppFeature

/// Loom's panel used to read the system proxy only at boot, right after its own change,
/// and on quit. So when Charles or whistle took the setting while the panel was open,
/// the switch kept claiming "on" until the human closed and reopened it — a stale
/// control for the setting that decides whether anything is captured at all.
///
/// `SetupFeature` now follows the setting live. These pin the reducer half: that a
/// change is believed, that "someone else has it" survives as its own state rather than
/// decaying to a bare `false`, and that our *own* half-applied writes don't flicker it.
@MainActor
@Suite struct SystemProxyPreemptionTests {
    private func snapshot(host: String, port: Int) -> SystemProxySnapshot {
        SystemProxySnapshot(
            httpEnabled: true, httpHost: host, httpPort: port,
            httpsEnabled: true, httpsHost: host, httpsPort: port
        )
    }

    private func store(port: Int = 9090, isSystemProxy: Bool = false) -> TestStore<SetupFeature.State, SetupFeature.Action> {
        var initial = SetupFeature.State()
        initial.port = port
        initial.isSystemProxy = isSystemProxy
        initial.systemProxyRouting = isSystemProxy ? .loom : .off
        return TestStore(initialState: initial) { SetupFeature() }
    }

    /// The regression: another proxy app takes the setting, and Loom's switch follows
    /// without anyone reopening the panel.
    @Test func anotherProxyTakingOverFlipsTheSwitchOff() async {
        let store = store(isSystemProxy: true)

        await store.send(.systemProxySnapshotChanged(snapshot(host: "127.0.0.1", port: 8888))) {
            $0.systemProxyRouting = .other(host: "127.0.0.1", port: 8888)
            $0.isSystemProxy = false
        }
    }

    /// "Occupied" must not decay into "off" — the two need different advice ("quit
    /// Charles" vs "press the switch"), which is why the boolean alone wasn't enough.
    @Test func occupiedIsDistinctFromOff() async {
        let store = store(isSystemProxy: true)

        await store.send(.systemProxySnapshotChanged(SystemProxySnapshot.off)) {
            $0.systemProxyRouting = .off
            $0.isSystemProxy = false
        }
    }

    @Test func routingBackToLoomFlipsTheSwitchOn() async {
        let store = store()

        await store.send(.systemProxySnapshotChanged(snapshot(host: "127.0.0.1", port: 9090))) {
            $0.systemProxyRouting = .loom
            $0.isSystemProxy = true
        }
    }

    /// Classified against the port as of *delivery*, not as of subscription: phone
    /// onboarding rebinds the proxy, so a snapshot aimed at the old port is not us.
    @Test func theCurrentPortDecides() async {
        let store = store(port: 9091)

        await store.send(.systemProxySnapshotChanged(snapshot(host: "127.0.0.1", port: 9090))) {
            $0.systemProxyRouting = .other(host: "127.0.0.1", port: 9090)
            $0.isSystemProxy = false
        }
    }

    /// Our own enable script writes one network service at a time, so mid-apply
    /// snapshots are genuinely half-applied. Believing them would fight the optimistic
    /// toggle and flicker the switch; `.systemProxyResult` re-reads once it settles.
    @Test func snapshotsAreIgnoredWhileOurOwnChangeIsInFlight() async {
        var initial = SetupFeature.State()
        initial.port = 9090
        initial.isSystemProxy = true      // optimistic value set by the toggle
        initial.systemProxyBusy = true
        let store = TestStore(initialState: initial) { SetupFeature() }

        // No state change expected.
        await store.send(.systemProxySnapshotChanged(SystemProxySnapshot.off))
        #expect(store.state.isSystemProxy, "a mid-apply snapshot must not undo the optimistic toggle")
    }

    /// After a change settles, the truth is re-read — and on the disable path that truth
    /// may be *another app's* proxy (one that re-claimed the setting the moment Loom let
    /// go), not simply "off". Loom itself never restores a previous owner.
    @Test func afterADisableAnotherOwnersProxyIsReflected() async {
        var initial = SetupFeature.State()
        initial.port = 9090
        initial.isSystemProxy = false
        initial.systemProxyBusy = true
        let restored = snapshot(host: "127.0.0.1", port: 8888)
        let store = TestStore(initialState: initial) { SetupFeature() } withDependencies: {
            $0.privilegedHelperClient.systemProxySnapshot = { restored }
        }

        await store.send(.systemProxyResult(enabling: false, ok: true, message: nil)) {
            $0.systemProxyBusy = false
            $0.systemProxyMessage = nil
        }
        await store.receive(\.systemProxySnapshotChanged) {
            $0.systemProxyRouting = .other(host: "127.0.0.1", port: 8888)
            $0.isSystemProxy = false
        }
    }

    /// The reported bug: after a successful enable the panel showed "On — QUIC blocked…
    /// Restored when Loom quits." Nothing ever cleared it, so once another proxy app
    /// took the setting the row correctly read "in use by 127.0.0.1:8888" while the line
    /// underneath still claimed Loom held it.
    ///
    /// The fix is structural rather than another clearing rule: a note describing
    /// current routing is derived by the panel from `systemProxyRouting`, so the
    /// reducer must store **no** standing claim on success. Transient feedback about an
    /// action (errors, "Setting system proxy…") is still stored — that's what the field
    /// is for.
    @Test func aSuccessfulEnableStoresNoStandingClaim() async {
        var initial = SetupFeature.State()
        initial.port = 9090
        initial.isSystemProxy = true
        initial.systemProxyBusy = true
        initial.systemProxyMessage = "Setting system proxy…"
        // Built outside the dependency closure: the escaping closure isn't main-actor
        // isolated, so it can't reach this suite's helper.
        let onLoom = snapshot(host: "127.0.0.1", port: 9090)
        let store = TestStore(initialState: initial) { SetupFeature() } withDependencies: {
            $0.privilegedHelperClient.systemProxySnapshot = { onLoom }
        }

        await store.send(.systemProxyResult(enabling: true, ok: true, message: nil)) {
            $0.systemProxyBusy = false
            $0.systemProxyMessage = nil
        }
        await store.receive(\.systemProxySnapshotChanged) { $0.systemProxyRouting = .loom }

        // And when someone else takes it, there is no leftover text to contradict the
        // row — the note simply follows the new routing.
        await store.send(.systemProxySnapshotChanged(snapshot(host: "127.0.0.1", port: 8888))) {
            $0.systemProxyRouting = .other(host: "127.0.0.1", port: 8888)
            $0.isSystemProxy = false
        }
        #expect(store.state.systemProxyMessage == nil)
    }

    /// A failed enable reverts the optimistic toggle *and* settles on what the system
    /// really says, so a partial write can't leave the row lying in the other direction.
    /// Starts from a stale `.loom` — the state a previous reading left behind — so the
    /// settling read is observable rather than a no-op.
    @Test func aFailedEnableRevertsAndThenSettles() async {
        var initial = SetupFeature.State()
        initial.port = 9090
        initial.isSystemProxy = true      // optimistic
        initial.systemProxyRouting = .loom
        initial.systemProxyBusy = true
        let store = TestStore(initialState: initial) { SetupFeature() } withDependencies: {
            $0.privilegedHelperClient.systemProxySnapshot = { .off }
        }

        await store.send(.systemProxyResult(enabling: true, ok: false, message: "Authorization cancelled.")) {
            $0.systemProxyBusy = false
            $0.isSystemProxy = false
            $0.systemProxyMessage = "Authorization cancelled."
        }
        await store.receive(\.systemProxySnapshotChanged) {
            $0.systemProxyRouting = .off
        }
    }
}
