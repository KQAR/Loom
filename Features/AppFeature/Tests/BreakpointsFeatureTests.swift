import ComposableArchitecture
import Foundation
import LoomSharedModels
import Testing

@testable import AppFeature

/// `TestStore` coverage for `BreakpointsFeature` — the human half of breakpoints.
/// What's asserted is the part that makes the surface trustworthy: a hold that
/// arrives on the stream shows up exactly once, every release re-syncs from the
/// engine (a hold can resolve without us), and the held-poll runs only while
/// something is actually held.
@MainActor
@Suite struct BreakpointsFeatureTests {
    private struct StubError: LocalizedError {
        var errorDescription: String? { "already resolved" }
    }

    private static func breakpoint(
        id: UUID = UUID(),
        pattern: String = "https://api.example.com/v1/pay"
    ) -> Breakpoint {
        Breakpoint(
            id: id,
            match: RuleMatch(urlPattern: pattern),
            onRequest: true,
            onResponse: false,
            createdAt: Fixtures.epoch
        )
    }

    private static func held(
        id: UUID = UUID(),
        breakpointID: UUID = UUID(),
        phase: BreakpointPhase = .request,
        url: String = "https://api.example.com/v1/pay"
    ) -> PendingBreakpoint {
        PendingBreakpoint(
            id: id,
            breakpointID: breakpointID,
            phase: phase,
            method: "POST",
            url: url,
            requestHeaders: [],
            heldAt: Fixtures.epoch
        )
    }

    // MARK: Mirroring the engine

    @Test func refresh_mirrorsArmedAndHeldFromTheEngine() async {
        let armed = Self.breakpoint()
        let pending = Self.held(breakpointID: armed.id)
        let clock = TestClock()
        let store = TestStore(initialState: BreakpointsFeature.State()) { BreakpointsFeature() } withDependencies: {
            $0.proxyClient.armedBreakpoints = { [armed] }
            $0.proxyClient.pendingBreakpoints = { [pending] }
            $0.continuousClock = clock
        }

        await store.send(.refresh)
        await store.receive(\.loaded) {
            $0.armed = [armed]
            $0.pending = [pending]
            $0.polling = true // something is held → the poll starts
        }
        // Land back on "nothing held" so the poll effect is cancelled before the
        // store is torn down (an in-flight effect fails the test otherwise).
        await store.send(.loaded(armed: [], pending: [])) {
            $0.armed = []
            $0.pending = []
            $0.polling = false
        }
    }

    /// The stream can beat the seed read, so an arriving hold is an upsert. Showing
    /// the same parked connection twice would have the human release one "of them"
    /// and see the other still sitting there.
    @Test func pendingReceived_isAnUpsert_notAnAppend() async {
        let pending = Self.held()
        let clock = TestClock()
        let store = TestStore(initialState: BreakpointsFeature.State()) { BreakpointsFeature() } withDependencies: {
            $0.proxyClient.armedBreakpoints = { [] }
            $0.proxyClient.pendingBreakpoints = { [] }
            $0.continuousClock = clock
        }

        await store.send(.pendingReceived(pending)) {
            $0.pending = [pending]
            $0.polling = true
        }
        await store.send(.pendingReceived(pending)) // same hold again
        #expect(store.state.pending.count == 1)

        await store.send(.loaded(armed: [], pending: [])) {
            $0.pending = []
            $0.polling = false
        }
    }

    // MARK: Releasing a hold

    @Test func resumeTapped_releasesUnmodified_thenResyncs() async {
        let pending = Self.held()
        let released = LockIsolated<(id: UUID, abort: Bool, edit: BreakpointEdit)?>(nil)
        var initial = BreakpointsFeature.State()
        initial.pending = [pending]
        initial.polling = true
        let clock = TestClock()
        let store = TestStore(initialState: initial) { BreakpointsFeature() } withDependencies: {
            $0.proxyClient.resumeBreakpoint = { id, abort, edit in
                released.setValue((id, abort, edit))
            }
            $0.proxyClient.armedBreakpoints = { [] }
            $0.proxyClient.pendingBreakpoints = { [] }
            $0.continuousClock = clock
        }

        await store.send(.resumeTapped(pending.id)) {
            $0.pending = []
            $0.polling = false // nothing held → the poll stops
        }
        await store.receive(\.refresh)
        await store.receive(\.loaded)

        #expect(released.value?.id == pending.id)
        #expect(released.value?.abort == false)
        // The human's release never edits the exchange — that's the agent's job.
        #expect(released.value?.edit == BreakpointEdit.none)
    }

    @Test func abortTapped_passesAbortThrough() async {
        let pending = Self.held()
        let released = LockIsolated<Bool?>(nil)
        var initial = BreakpointsFeature.State()
        initial.pending = [pending]
        initial.polling = true
        let store = TestStore(initialState: initial) { BreakpointsFeature() } withDependencies: {
            $0.proxyClient.resumeBreakpoint = { _, abort, _ in released.setValue(abort) }
            $0.proxyClient.armedBreakpoints = { [] }
            $0.proxyClient.pendingBreakpoints = { [] }
            $0.continuousClock = TestClock()
        }

        await store.send(.abortTapped(pending.id)) {
            $0.pending = []
            $0.polling = false
        }
        await store.receive(\.refresh)
        await store.receive(\.loaded)
        #expect(released.value == true)
    }

    /// A hold that already resolved on its own (client hung up, watchdog fired)
    /// makes `resume` throw. The optimistic removal stands, the reason is shown,
    /// and the re-sync is what puts the list back in step with the engine.
    @Test func resumeTapped_failure_surfacesTheReason_andStillResyncs() async {
        let pending = Self.held()
        let stillHeld = Self.held()
        var initial = BreakpointsFeature.State()
        initial.pending = [pending, stillHeld]
        initial.polling = true
        let store = TestStore(initialState: initial) { BreakpointsFeature() } withDependencies: {
            $0.proxyClient.resumeBreakpoint = { _, _, _ in throw StubError() }
            $0.proxyClient.armedBreakpoints = { [] }
            $0.proxyClient.pendingBreakpoints = { [stillHeld] }
            $0.continuousClock = TestClock()
        }

        await store.send(.resumeTapped(pending.id)) { $0.pending = [stillHeld] }
        await store.receive(\.writeFailed) {
            $0.message = "Couldn’t resume the held exchange: already resolved"
        }
        await store.receive(\.refresh)
        // Engine truth matches the optimistic removal exactly — the surviving hold
        // is still held, the resolved one is gone.
        await store.receive(\.loaded)

        await store.send(.loaded(armed: [], pending: [])) { // cancel the poll
            $0.pending = []
            $0.polling = false
        }
    }

    // MARK: Disarm

    @Test func disarmTapped_removesOptimistically_thenAdoptsEngineTruth() async {
        let armed = Self.breakpoint()
        let survivor = Self.breakpoint(pattern: "https://api.example.com/v1/login")
        var initial = BreakpointsFeature.State()
        initial.armed = [armed, survivor]
        initial.message = "stale error"
        let store = TestStore(initialState: initial) { BreakpointsFeature() } withDependencies: {
            $0.proxyClient.disarmBreakpoint = { _ in }
            $0.proxyClient.armedBreakpoints = { [survivor] }
            $0.proxyClient.pendingBreakpoints = { [] }
            $0.continuousClock = TestClock()
        }

        await store.send(.disarmTapped(armed.id)) {
            $0.message = nil
            $0.armed = [survivor]
        }
        await store.receive(\.refresh)
        await store.receive(\.loaded) // engine truth agrees with the optimistic removal
    }

    // MARK: The held-poll

    /// The poll exists for holds that resolve without a decision from us. It must
    /// run *only* while something is held — an always-on ticker would wake the
    /// reducer every two seconds for the whole life of the app.
    @Test func heldPoll_runsOnlyWhileSomethingIsHeld() async {
        let pending = Self.held()
        let clock = TestClock()
        let pendingReads = LockIsolated(0)
        let store = TestStore(initialState: BreakpointsFeature.State()) { BreakpointsFeature() } withDependencies: {
            $0.proxyClient.armedBreakpoints = { [] }
            $0.proxyClient.pendingBreakpoints = {
                pendingReads.withValue { $0 += 1 }
                return [pending]
            }
            $0.continuousClock = clock
        }
        store.exhaustivity = .off

        await store.send(.pendingReceived(pending))
        #expect(store.state.polling)

        await clock.advance(by: BreakpointsFeature.heldPollInterval)
        await store.receive(\.refresh)
        await store.receive(\.loaded)
        #expect(pendingReads.value == 1)

        // The hold goes away: the poll must stop, so further time reads nothing.
        // Driven through `.loaded` rather than a release so the assertion can't
        // race the release's own re-sync.
        await store.send(.loaded(armed: [], pending: []))
        #expect(!store.state.polling)
        let reads = pendingReads.value
        await clock.advance(by: BreakpointsFeature.heldPollInterval * 3)
        #expect(pendingReads.value == reads)
    }
}
