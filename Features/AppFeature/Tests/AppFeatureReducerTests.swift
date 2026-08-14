import AppKit
import ComposableArchitecture
import Foundation
import LoomSharedModels
import Testing

@testable import AppFeature

/// `TestStore` coverage for the parent `AppFeature` after the `RulesFeature`
/// split: boot idempotency, flow capture/replay/clear, and the cross-feature
/// seams (Add-Rule-from-flow → present editor, replay failure → rules message).
/// The rule CRUD itself is tested in `RulesFeatureTests`.
@MainActor
@Suite struct AppFeatureReducerTests {
    private struct StubError: LocalizedError {
        var errorDescription: String? { "replay failed" }
    }

    // MARK: Boot idempotency

    @Test func task_isNoOpOnceBooted() async {
        var initial = AppFeature.State()
        initial.didBoot = true // already booted; re-render must not restart the proxy
        let store = TestStore(initialState: initial) { AppFeature() }
        // No dependencies are overridden: if `.task` re-ran its effect it would
        // touch `proxyClient.start` (unimplemented) and fail the test.
        await store.send(.task)
    }

    // MARK: Add-Rule-from-flow seam (parent owns the flow store, child owns the editor)

    @Test func addRuleFromFlow_stampsRuleAndPresentsEditor() async {
        let flow = Fixtures.flow()
        var initial = AppFeature.State(flows: [flow])
        // Mock-from-flow now hydrates the full flow (bodies) via the client, since
        // the list holds metadata only.
        let store = TestStore(initialState: initial) { AppFeature() } withDependencies: {
            $0.proxyClient.flow = { _ in flow }
        }
        store.exhaustivity = .off // the stamped rule carries a fresh UUID/date

        await store.send(.capture(.addRuleFromFlow(flow.id, .mockResponse)))
        await store.receive(\.rules.presentEditor)
        #expect(store.state.rules.editor?.isNew ?? false)
        guard case .mock = store.state.rules.editor?.rule.actions.route else {
            Issue.record("expected a mock rule stamped from the flow")
            return
        }
    }

    @Test func addRuleFromFlow_unknownID_isNoOp() async {
        let store = TestStore(initialState: AppFeature.State()) { AppFeature() } withDependencies: {
            $0.proxyClient.flow = { _ in nil } // hydrate finds nothing → no editor
        }
        await store.send(.capture(.addRuleFromFlow(UUID(), .blockURL))) // no flow → nothing happens
    }

    // MARK: Replay failure routes into the shared rules message

    @Test func replayTapped_failure_surfacesInRulesMessage() async {
        let store = TestStore(initialState: AppFeature.State()) {
            AppFeature()
        } withDependencies: {
            $0.proxyClient.replay = { _, _ in throw StubError() }
        }
        await store.send(.capture(.replayTapped(UUID())))
        // Via the delegate rather than written across: the message line belongs to the
        // rules panel, and only the parent can see both of its writers.
        await store.receive(\.capture.delegate.replayFailed)
        await store.receive(\.rules.ruleWriteFailed) {
            $0.rules.rulesMessage = "Replay failed: replay failed"
        }
    }

    // MARK: Replay success

    @Test func replayFinished_insertsAndSelects() async {
        let original = UUID()
        let replayed = Fixtures.flow(id: UUID(), replayedFrom: original)
        let originalFlow = Fixtures.flow(id: original)
        let store = TestStore(initialState: AppFeature.State()) { AppFeature() } withDependencies: {
            $0.proxyClient.flow = { id in id == original ? originalFlow : nil }
        }
        await store.send(.capture(.replayFinished(replayed))) {
            $0.capture.recordFlow(replayed) // body-free in the list, counts + aggregates updated
            $0.capture.selectedFlowID = replayed.id // jump to the replayed result
            $0.capture.selectedFlowDetail = replayed // result still carries bodies
        }
        // Effect fetches the replay's original for the inspector diff.
        await store.receive(\.capture.selectedDetailLoaded) {
            $0.capture.selectedOriginalDetail = originalFlow
        }
    }

    @Test func replayFinished_nil_isNoOp() async {
        let store = TestStore(initialState: AppFeature.State()) { AppFeature() }
        await store.send(.capture(.replayFinished(nil)))
    }

    // MARK: Capture stream + clear

    @Test func flowReceived_appendsAndCounts() async {
        let flow = Fixtures.flow()
        // A capture also schedules the coalesced re-read of the engine's counters. The
        // clock keeps it from firing inside the assertion, and `exhaustivity = .off`
        // lets the test end with it still parked — what is under test is the fold.
        let store = TestStore(initialState: AppFeature.State()) { AppFeature() } withDependencies: {
            $0.continuousClock = TestClock()
        }
        store.exhaustivity = .off
        await store.send(.capture(.flowReceived(flow))) {
            $0.capture.recordFlow(flow) // metadata-only in the list; the counts come from the engine
        }
    }

    @Test func clearTapped_emptiesStore() async {
        let flow = Fixtures.flow()
        var initial = AppFeature.State(flows: [flow])
        initial.capture.selectedFlowID = flow.id
        initial.status.capturedCount = 1
        let store = TestStore(initialState: initial) {
            AppFeature()
        } withDependencies: {
            $0.proxyClient.clearFlows = { }
        }
        await store.send(.capture(.clearTapped)) {
            $0.capture.forgetCapturedFlows()
        }
    }

    /// An agent clearing the capture over MCP must empty the window too — otherwise
    /// the human supervises a list of flows the engine no longer holds.
    @Test func flowsClearedExternally_emptiesTheWindow() async {
        let flow = Fixtures.flow()
        var initial = AppFeature.State(flows: [flow])
        initial.capture.selectedFlowID = flow.id
        initial.capture.selectedFlowDetail = flow
        initial.status.capturedCount = 1
        initial.capture.droppedFlowCount = 7
        let store = TestStore(initialState: initial) { AppFeature() }

        await store.send(.capture(.flowsClearedExternally)) {
            $0.capture.forgetCapturedFlows()
        }
        // Idempotent: the echo of our own Clear must not be a second state change.
        await store.send(.capture(.flowsClearedExternally))
    }

    // MARK: The setup child's view of the proxy is projected, never mirrored

    /// `SetupFeature` decides whether the human may flip the system proxy, using
    /// the proxy's port and running state. Those live in the parent's `status`;
    /// the child reads a projection of them. Every path that moves `status` must
    /// therefore move the child's view with it, with nothing to remember.
    @Test func setupSeesTheProxyState_withoutAnyoneCopyingIt() async {
        let store = TestStore(initialState: AppFeature.State()) {
            AppFeature()
        } withDependencies: {
            $0.proxyClient.stop = {}
            // `proxyStarted` re-reads the engine's listener facts (the SOCKS and
            // reverse-proxy ports only exist once `start()` has returned).
            $0.proxyClient.status = { ProxyStatus(isRunning: true, port: 9191, capturedCount: 0, socksPort: 9192) }
        }
        #expect(store.state.setup.proxyRunning == false)

        await store.send(.proxyStarted(port: 9191)) {
            $0.status.isRunning = true
            $0.status.port = 9191
        }
        await store.receive(\.engineStatusRefreshed) {
            $0.status.socksPort = 9192
        }
        #expect(store.state.setup.proxyRunning, "started proxy, stale child")
        #expect(store.state.setup.port == 9191, "rebound port, stale child")

        await store.send(.toggleProxyTapped) {
            $0.status.isRunning = false
        }
        #expect(store.state.setup.proxyRunning == false, "stopped proxy, stale child")

        await store.send(.proxyStartFailed("port in use")) {
            $0.setup.systemProxyMessage = "Proxy failed to start: port in use"
        }
        #expect(store.state.setup.proxyRunning == false)
    }

    /// The child owns everything else in its state: a write from the child's own
    /// reducer must survive the projection.
    @Test func setupKeepsItsOwnState_throughTheProjection() async {
        var initial = AppFeature.State()
        initial.status.isRunning = true
        let store = TestStore(initialState: initial) { AppFeature() }
        await store.send(.setup(.systemProxyStateLoaded(true))) {
            $0.setup.isSystemProxy = true
        }
        #expect(store.state.setup.proxyRunning, "projection must not clobber the child's own fields")
    }

    @Test func toggleRecording_flips() async {
        let store = TestStore(initialState: AppFeature.State()) {
            AppFeature()
        } withDependencies: {
            $0.proxyClient.setRecording = { _ in }
        }
        await store.send(.toggleRecordingTapped) {
            $0.isRecording = false // starts true
        }
    }

    // MARK: The capture gate is the engine's, not a second copy

    /// `set_recording` is a write tool, so an agent can pause capture. `isRecording`
    /// used to be a local flag defaulting to `true` that nothing ever reconciled —
    /// the dot stayed green and the button kept offering "Stop" while the engine
    /// recorded nothing, which looks exactly like a broken proxy. Reopening a surface
    /// did not help, because no surface read the engine's answer.
    @Test func recordingFollowsTheEngine() async {
        let store = TestStore(initialState: AppFeature.State()) { AppFeature() }
        #expect(store.state.isRecording)

        await store.send(.engineStatusRefreshed(
            ProxyStatus(isRunning: true, port: 9090, capturedCount: 0, isRecording: false)
        )) {
            $0.status.isRecording = false
        }
        #expect(store.state.isRecording == false, "the toolbar must not claim to be recording")
    }

    // MARK: Every agent write reaches the human's copy of it

    private nonisolated func auditEntry(tool: String, succeeded: Bool = true) -> AuditEntry {
        AuditEntry(tool: tool, source: .mcp, succeeded: succeeded, arguments: "{}", detail: "ok")
    }

    /// The audit stream is the one signal every write tool passes through, so the
    /// re-read hangs off it. It used to fire for two tools out of twenty
    /// (`create_reverse_proxy`/`delete_reverse_proxy`), which left a rule, an
    /// SSL-scope carve-out or a client identity written by an agent invisible until
    /// the human reopened the surface — and the main window's `.task` fires once per
    /// launch, so for that surface "until they reopen it" means "until relaunch".
    @Test func anAgentRuleWrite_refreshesEveryMirror() async {
        let clock = TestClock()
        let store = TestStore(initialState: AppFeature.State()) { AppFeature() } withDependencies: {
            $0.continuousClock = clock
            $0.proxyClient.status = { ProxyStatus(isRunning: true, port: 9090, capturedCount: 0) }
            $0.proxyClient.rulesState = { RulesState() }
            $0.proxyClient.certificateStatus = { .notGenerated }
            $0.proxyClient.sslScope = { .disabled }
            $0.proxyClient.tunneledHosts = { TunneledHostReport() }
            $0.proxyClient.clientCertificates = { [] }
        }
        store.exhaustivity = .off

        await store.send(.audit(.entryReceived(auditEntry(tool: "set_rule"))))
        await store.receive(\.audit.delegate.mirroredStateWriteRecorded)
        await clock.advance(by: AppFeature.mirrorRefreshDebounce)
        await store.receive(\.engineStatusRefreshed)
        await store.receive(\.rules.refreshRules)
        await store.receive(\.setup.refreshAgentWritable)
    }

    /// The opt-out. These already reach the human through their own subscription, and
    /// `replay_flow` arrives in batches — re-reading every mirror a hundred times
    /// would be pure waste.
    @Test func aStreamedWrite_doesNotRefreshAnything() async {
        let store = TestStore(initialState: AppFeature.State()) { AppFeature() }
        for tool in ["replay_flow", "clear_flows", "import_har",
                     "arm_breakpoint", "disarm_breakpoint", "resume"] {
            let entry = auditEntry(tool: tool)
            await store.send(.audit(.entryReceived(entry))) {
                $0.audit.entries.append(entry)
            }
        }
    }

    /// A failed write changed nothing, so there is nothing to re-read. It still lands
    /// in the trail — "the agent tried and it failed" is what a supervisor needs.
    @Test func aFailedWrite_doesNotRefresh() async {
        let entry = auditEntry(tool: "set_ssl_scope", succeeded: false)
        let store = TestStore(initialState: AppFeature.State()) { AppFeature() }
        await store.send(.audit(.entryReceived(entry))) {
            $0.audit.entries.append(entry)
        }
    }

    // MARK: Coming back to Loom re-reads what a human changed elsewhere

    /// The audit-stream refresh covers the writer that is an agent. CA trust has a
    /// different one: Loom prints a `sudo security add-trusted-cert` line and the
    /// human runs it in Terminal, or revokes it later in Keychain Access. Neither is
    /// a write tool, and the main window's `.task` fires once per launch — so its
    /// "Not trusted" row kept saying so afterwards.
    @Test func appActivation_yieldsWhenLoomComesToTheFront() async {
        var iterator = AppActivation.events().makeAsyncIterator()  // registers now
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        let received: Void? = await iterator.next()
        #expect(received != nil, "activation must reach the reducer")
    }

    /// …and what activation triggers is the re-read, `certificateStatus` included.
    @Test func viewAppeared_reReadsTheTrustState() async {
        let store = TestStore(initialState: AppFeature.State()) { AppFeature() } withDependencies: {
            $0.proxyClient.status = { ProxyStatus(isRunning: true, port: 9090, capturedCount: 0) }
            $0.proxyClient.rulesState = { RulesState() }
            $0.proxyClient.sslScope = { .disabled }
            $0.proxyClient.tunneledHosts = { TunneledHostReport() }
            $0.proxyClient.clientCertificates = { [] }
            $0.proxyClient.certificateStatus = {
                CertificateStatus(
                    isGenerated: true, isTrusted: true, commonName: "Loom Root CA",
                    sha256Fingerprint: "AA:BB", notAfter: Date(timeIntervalSince1970: 0)
                )
            }
            $0.proxyClient.armedBreakpoints = { [] }
            $0.proxyClient.pendingBreakpoints = { [] }
            $0.updaterClient.checkInBackgroundIfDue = { }
            $0.privilegedHelperClient.systemProxySnapshot = { .off }
            $0.privilegedHelperClient.helperState = { .notInstalled }
            $0.privilegedHelperClient.helperFailureReason = { nil }
        }
        store.exhaustivity = .off

        await store.send(.viewAppeared)
        await store.receive(\.setup.certificateStatusLoaded)
        #expect(store.state.setup.certificateStatus.isTrusted,
                "trust granted outside Loom must land without a relaunch")
    }

    // MARK: The QR follows the machine

    /// The published material freezes an address: the QR encodes
    /// `http://lanHost:provisioningPort/` and the popover prints `lanHost:proxyPort`
    /// for the phone's manual proxy fields. Move networks and that QR points at a
    /// host which no longer answers — a phone scanning it hangs with nothing to say
    /// why. `startPhoneOnboarding` is idempotent and republishes; these pin *when*
    /// it is re-run.
    private nonisolated func onboardingInfo(host: String) -> PhoneOnboardingInfo {
        PhoneOnboardingInfo(
            lanHost: host,
            proxyPort: 9090,
            provisioningPort: 9500,
            provisioningURL: URL(string: "http://\(host):9500/")!,
            fingerprint: "AA:BB",
            commonName: "Loom Root CA",
            qrPNGData: Data()
        )
    }

    @Test func lanAddressMoves_republishesTheOnboardingMaterial() async {
        var initial = AppFeature.State()
        initial.lanEnabled = true
        initial.publishedLANHost = "192.168.1.42"
        let clock = TestClock()
        let republished = onboardingInfo(host: "10.0.0.7")
        let store = TestStore(initialState: initial) { AppFeature() } withDependencies: {
            $0.continuousClock = clock
            $0.proxyClient.startPhoneOnboarding = { republished }
        }

        await store.send(.localIPResolved("10.0.0.7")) {
            $0.localIP = "10.0.0.7"
        }
        await clock.advance(by: AppFeature.phoneRepublishDebounce)
        await store.receive(\.phoneOnboardingPublished) {
            $0.publishedLANHost = "10.0.0.7"
        }
    }

    /// A Wi-Fi join settles over several addresses. Republishing on each would
    /// rebind the provisioning server repeatedly, and the engine refuses a second
    /// concurrent `startPhoneOnboarding` outright — so an un-debounced burst can end
    /// with the *last* address never published, which is the failure this fixes.
    @Test func lanAddressFlapping_republishesOnceForTheAddressItSettledOn() async {
        var initial = AppFeature.State()
        initial.lanEnabled = true
        initial.publishedLANHost = "192.168.1.42"
        let clock = TestClock()
        let calls = LockIsolated(0)
        let store = TestStore(initialState: initial) { AppFeature() } withDependencies: {
            $0.continuousClock = clock
            $0.proxyClient.startPhoneOnboarding = {
                calls.withValue { $0 += 1 }
                return self.onboardingInfo(host: "10.0.0.9")
            }
        }

        await store.send(.localIPResolved("10.0.0.7")) { $0.localIP = "10.0.0.7" }
        await clock.advance(by: .seconds(1))     // still settling
        await store.send(.localIPResolved("10.0.0.9")) { $0.localIP = "10.0.0.9" }
        await clock.advance(by: AppFeature.phoneRepublishDebounce)

        await store.receive(\.phoneOnboardingPublished) {
            $0.publishedLANHost = "10.0.0.9"
        }
        #expect(calls.value == 1, "the in-flight republish must be cancelled, not queued")
    }

    /// Going offline publishes nothing: the engine would refuse for want of a LAN
    /// address, and the material Loom holds is the last one that ever worked.
    @Test func lanAddressLost_doesNotRepublish() async {
        var initial = AppFeature.State()
        initial.lanEnabled = true
        initial.publishedLANHost = "192.168.1.42"
        initial.localIP = "192.168.1.42"
        // `startPhoneOnboarding` is left unimplemented: calling it fails the test.
        let store = TestStore(initialState: initial) { AppFeature() }
        await store.send(.localIPResolved(nil)) { $0.localIP = nil }
    }

    @Test func lanDisabled_doesNotRepublish() async {
        var initial = AppFeature.State()
        initial.lanEnabled = false
        // `startPhoneOnboarding` is left unimplemented: calling it fails the test.
        let store = TestStore(initialState: initial) { AppFeature() }
        await store.send(.localIPResolved("10.0.0.7")) { $0.localIP = "10.0.0.7" }
    }

    /// The address that is already published is not a change. Without this the
    /// first emission of the address stream — which seeds the current value — would
    /// republish on top of what boot just published.
    @Test func sameAddressAgain_doesNotRepublish() async {
        var initial = AppFeature.State()
        initial.lanEnabled = true
        initial.publishedLANHost = "192.168.1.42"
        let store = TestStore(initialState: initial) { AppFeature() }
        await store.send(.localIPResolved("192.168.1.42")) { $0.localIP = "192.168.1.42" }
    }

    /// Turning LAN off drops the material and returns the listener to loopback, so
    /// the address it was published for has to be forgotten too — keeping it would
    /// make the next address change look like a republish that already happened.
    @Test func lanTurnedOff_forgetsThePublishedAddress() async {
        var initial = AppFeature.State()
        initial.lanEnabled = true
        initial.publishedLANHost = "192.168.1.42"
        initial.phone = PhoneOnboardingFeature.State(lanEnabled: true)
        let store = TestStore(initialState: initial) { AppFeature() } withDependencies: {
            $0.proxyClient.status = { ProxyStatus(isRunning: true, port: 9090, capturedCount: 0) }
        }
        store.exhaustivity = .off

        await store.send(.phone(.presented(.delegate(.lanEnabledChanged(false)))))
        #expect(store.state.publishedLANHost == nil)
    }

    /// An open popover is showing the material the republish just replaced. It is
    /// usually *not* open when this lands — the address moves whether or not anyone
    /// is looking — which is why the parent writes the child's state directly rather
    /// than sending an action into a possibly-nil presentation.
    @Test func republish_refreshesAnOpenPopover() async {
        var initial = AppFeature.State()
        initial.lanEnabled = true
        initial.publishedLANHost = "192.168.1.42"
        initial.phone = PhoneOnboardingFeature.State(
            lanEnabled: true, info: onboardingInfo(host: "192.168.1.42")
        )
        let fresh = onboardingInfo(host: "10.0.0.7")
        let store = TestStore(initialState: initial) { AppFeature() }

        await store.send(.phoneOnboardingPublished(fresh)) {
            $0.publishedLANHost = "10.0.0.7"
            $0.phone?.info = fresh
        }
        #expect(store.state.phone?.info?.provisioningURL.absoluteString == "http://10.0.0.7:9500/")
    }

    /// A row's `Pass Through` goes through the same `SetupFeature` write the console
    /// card makes, so the two surfaces cannot drift on what it means. The stale include
    /// entry for the same host is dropped in the same write, or the two lists would
    /// disagree about it.
    @Test func aRowPassingAHostThrough_writesAnExclude() async {
        let written = LockIsolated<SSLScope?>(nil)
        let expected = SSLScope(enabled: true, include: ["*"], exclude: ["pinned.example.com"])
        var state = AppFeature.State()
        state.setup.sslEnabled = true
        state.setup.sslScope = SSLScope(enabled: true, include: ["*"])
        let store = TestStore(initialState: state) { AppFeature() } withDependencies: {
            $0.proxyClient.setSSLScope = { written.setValue($0) }
            $0.proxyClient.sslScope = { expected }
            $0.proxyClient.tunneledHosts = { TunneledHostReport() }
        }
        store.exhaustivity = .off

        await store.send(.capture(.excludeHostTapped("pinned.example.com")))
        await store.receive(\.capture.delegate.excludeHost)
        await store.receive(\.setup.excludeHostTapped)
        await store.receive(\.setup.sslScopeLoaded)
        #expect(written.value?.exclude == ["pinned.example.com"])
        #expect(written.value?.include == ["*"], "the wildcard is untouched — one host is carved out of it")
    }

    /// **Decrypting a host must not empty the request table.** The rows already in the
    /// window are a record of what happened; a scope write decides how the *next*
    /// connection is treated and has no claim on them. This is the one direction the
    /// whitelist makes easy to get wrong, because the console's tunnelled list *is*
    /// filtered against the current scope (`TunneledHostLog.pending`) and the table
    /// deliberately is not.
    @Test func decryptingAHost_leavesTheCapturedRowsAlone() async {
        let relayed = Fixtures.flow(method: "CONNECT", url: "https://unnamed.example.com:443")
        let other = Fixtures.flow(url: "https://kept.example.com/v1")
        var state = AppFeature.State(flows: [relayed, other])
        state.setup.sslEnabled = true
        state.setup.sslScope = SSLScope(enabled: true, include: [])
        let store = TestStore(initialState: state) { AppFeature() } withDependencies: {
            $0.proxyClient.interceptHost = { _ in InterceptOutcome() }
            $0.proxyClient.sslScope = { SSLScope(enabled: true, include: ["unnamed.example.com"]) }
            $0.proxyClient.tunneledHosts = { TunneledHostReport() }
        }
        store.exhaustivity = .off

        #expect(store.state.capture.displayFlowsAreEmpty == false)
        await store.send(.capture(.decryptHostTapped("unnamed.example.com")))
        await store.receive(\.setup.sslScopeLoaded)

        #expect(store.state.capture.flows.count == 2)
        #expect(store.state.capture.displayFlowsAreEmpty == false,
                "the table shows what happened; the scope decides what happens next")
        #expect(store.state.capture.displayFlows.map(\.id) == [relayed.id, other.id])
    }

    /// And the other direction, which is the primary one under a whitelist: a relayed
    /// `CONNECT` row is how the operator meets an un-named origin at all, so its
    /// Decrypt has to reach the same scope. It routes to `interceptHostTapped`, which
    /// writes **atomically through the engine** — the console and an agent are
    /// independent writers, and a read-modify-write here would lose one of them.
    @Test func aRowDecryptingAHost_goesThroughTheEnginesAtomicWrite() async {
        let asked = LockIsolated<String?>(nil)
        let after = SSLScope(enabled: true, include: ["unnamed.example.com"])
        var state = AppFeature.State()
        state.setup.sslEnabled = true
        state.setup.sslScope = SSLScope(enabled: true, include: [])
        let store = TestStore(initialState: state) { AppFeature() } withDependencies: {
            $0.proxyClient.interceptHost = { host in
                asked.setValue(host)
                return InterceptOutcome()
            }
            $0.proxyClient.sslScope = { after }
            $0.proxyClient.tunneledHosts = { TunneledHostReport() }
        }
        store.exhaustivity = .off

        await store.send(.capture(.decryptHostTapped("unnamed.example.com")))
        await store.receive(\.capture.delegate.decryptHost)
        await store.receive(\.setup.interceptHostTapped)
        await store.receive(\.setup.sslScopeLoaded)
        #expect(asked.value == "unnamed.example.com")
        #expect(store.state.setup.sslScope.include == ["unnamed.example.com"])
    }

    /// And a second click on the same host reports that it changed nothing, rather
    /// than repeating the success sentence: the window's row menu can reach a host the
    /// console excluded minutes ago.
    @Test func aRowPassingAnAlreadyExcludedHostThrough_saysSo() async {
        var state = AppFeature.State()
        state.setup.sslEnabled = true
        state.setup.sslScope = SSLScope(enabled: true, include: ["*"], exclude: ["pinned.example.com"])
        let store = TestStore(initialState: state) { AppFeature() } withDependencies: {
            $0.proxyClient.setSSLScope = { _ in Issue.record("nothing to write") }
        }
        store.exhaustivity = .off

        await store.send(.capture(.excludeHostTapped("pinned.example.com")))
        await store.receive(\.setup.excludeHostTapped)
        #expect(store.state.setup.sslScopeMessage == "pinned.example.com is already passed through.")
    }
}
