import ComposableArchitecture
import Foundation
import LoomSharedModels
import Testing
@testable import AppFeature

/// The console's *write* half of reverse-proxy endpoints — creating and removing one
/// from the status-bar panel, which was agent-only before.
///
/// What these pin is the two things a create can't fake: that the list the panel
/// draws comes from a re-read of the engine (so the *bound* port shows, not the
/// requested one), and that a failed create says why instead of quietly doing nothing.
@Suite struct ReverseProxyConsoleTests {
    private func endpoint(
        port: Int = 9200, upstream: String = "https://api.github.com", bound: Int? = 9200,
        error: String? = nil
    ) -> ReverseProxyStatus {
        ReverseProxyStatus(
            endpoint: ReverseProxyEndpoint(requestedPort: port, upstream: upstream),
            boundPort: bound, error: error
        )
    }

    /// Blank port in the form means "any free one" (requested 0), and the OS's choice
    /// is the number the human has to type into a config file — so the create is
    /// followed by a status re-read rather than by trusting what was submitted.
    @MainActor
    @Test func creatingAnEndpointReReadsTheEngineSoTheBoundPortIsWhatShows() async {
        let created = endpoint(port: 0, bound: 54_321)
        let store = TestStore(initialState: AppFeature.State()) {
            AppFeature()
        } withDependencies: {
            $0.proxyClient.createReverseProxy = { _ in created }
            $0.proxyClient.status = {
                ProxyStatus(isRunning: true, port: 9090, capturedCount: 0, reverseProxies: [created])
            }
        }

        await store.send(.reverseProxy(.addTapped(
            upstream: "https://api.github.com", port: 0, label: nil, keepHostHeader: false
        ))) {
            $0.reverseProxy.isBusy = true
        }
        // The re-read is now a hop through the child's delegate, so it lands after
        // `finished` rather than before it: the child asks, the parent (which owns
        // `status`) does the reading. The list is refreshed either way — what moved is
        // only when the spinner stops relative to it.
        await store.receive(\.reverseProxy.delegate.needsStatusRefresh)
        await store.receive(\.reverseProxy.finished) {
            $0.reverseProxy.isBusy = false
        }
        await store.receive(\.engineStatusRefreshed) {
            $0.status.port = 9090
            $0.status.reverseProxies = [created]
        }
        #expect(store.state.status.reverseProxies.first?.localURL == "http://127.0.0.1:54321")
        #expect(store.state.reverseProxy.message == nil)
    }

    /// A create binds before it persists, so the common failure — the port is already
    /// taken by the very dev server the endpoint was made for — arrives as a throw.
    /// The engine's message names the port, so it is relayed verbatim rather than
    /// replaced with "couldn't add".
    @MainActor
    @Test func aFailedCreateSurfacesTheEnginesReasonAndClearsBusy() async {
        let store = TestStore(initialState: AppFeature.State()) {
            AppFeature()
        } withDependencies: {
            $0.proxyClient.createReverseProxy = { _ in
                throw ProxyControlError.invalidReverseProxy("port 9200 is already in use")
            }
        }

        await store.send(.reverseProxy(.addTapped(
            upstream: "https://api.github.com", port: 9200, label: nil, keepHostHeader: false
        ))) {
            $0.reverseProxy.isBusy = true
        }
        await store.receive(\.reverseProxy.finished) {
            $0.reverseProxy.isBusy = false
            // Verbatim from `ProxyControlError.message`, kind prefix included: the
            // panel shows the engine's wording, not a rewrite of it.
            $0.reverseProxy.message = "invalid reverse proxy: port 9200 is already in use"
        }
        // No status re-read on failure: nothing changed, and a refresh would imply it did.
        #expect(store.state.status.reverseProxies.isEmpty)
    }

    @MainActor
    @Test func removingAnEndpointDropsItFromTheListThePanelDraws() async {
        let existing = endpoint()
        var state = AppFeature.State()
        state.status.reverseProxies = [existing]
        let store = TestStore(initialState: state) {
            AppFeature()
        } withDependencies: {
            $0.proxyClient.deleteReverseProxy = { _ in }
            $0.proxyClient.status = { ProxyStatus(isRunning: true, port: 9090, capturedCount: 0) }
        }

        await store.send(.reverseProxy(.deleteTapped(id: existing.endpoint.id))) {
            $0.reverseProxy.isBusy = true
        }
        await store.receive(\.reverseProxy.delegate.needsStatusRefresh)
        await store.receive(\.reverseProxy.finished) {
            $0.reverseProxy.isBusy = false
        }
        await store.receive(\.engineStatusRefreshed) {
            $0.status.port = 9090
            $0.status.reverseProxies = []
        }
    }

    /// Opening the section re-reads, because the other writer is an agent: an endpoint
    /// created over MCP since the last refresh would otherwise be missing from the list
    /// the human just opened to check.
    @MainActor
    @Test func openingTheSectionReReadsTheEndpoints() async {
        let agents = endpoint(port: 9300, upstream: "https://api.stripe.com", bound: 9300)
        let store = TestStore(initialState: AppFeature.State()) {
            AppFeature()
        } withDependencies: {
            $0.proxyClient.status = {
                ProxyStatus(isRunning: true, port: 9090, capturedCount: 0, reverseProxies: [agents])
            }
        }

        await store.send(.reverseProxy(.expandTapped)) {
            $0.reverseProxy.isExpanded = true
        }
        await store.receive(\.reverseProxy.delegate.needsStatusRefresh)
        await store.receive(\.engineStatusRefreshed) {
            $0.status.port = 9090
            $0.status.reverseProxies = [agents]
        }

        // Collapsing reads nothing — there is no list on screen to keep fresh.
        await store.send(.reverseProxy(.expandTapped)) {
            $0.reverseProxy.isExpanded = false
        }
    }

    // MARK: The plumbing that makes the list reachable at all

    /// `state.status` is still partly the parent's (the toggle owns `isRunning`), and
    /// nothing used to read the engine's own copy — so `socksPort` and `reverseProxies`
    /// were always empty. Opening the panel re-reads them.
    @MainActor
    @Test func openingThePanelReadsTheEnginesListenerFacts() async {
        let listening = endpoint()
        let store = TestStore(initialState: AppFeature.State()) {
            AppFeature()
        } withDependencies: {
            $0.proxyClient.status = {
                ProxyStatus(
                    isRunning: true, port: 9090, capturedCount: 77, socksPort: 9091,
                    reverseProxies: [listening]
                )
            }
            // `viewAppeared` also re-syncs the other children and runs the once-a-day
            // update probe. Stubbed rather than asserted — the listener re-read is what
            // is under test, and `exhaustivity = .off` ignores their state changes but
            // not their unimplemented dependencies.
            $0.updaterClient.checkInBackgroundIfDue = {}
            $0.privilegedHelperClient.systemProxySnapshot = { SystemProxySnapshot() }
            $0.privilegedHelperClient.helperState = { .notInstalled }
            $0.privilegedHelperClient.helperFailureReason = { nil }
            $0.proxyClient.rulesState = { RulesState() }
            $0.proxyClient.armedBreakpoints = { [] }
            $0.proxyClient.pendingBreakpoints = { [] }
            $0.proxyClient.certificateStatus = { .notGenerated }
            $0.proxyClient.sslScope = { .disabled }
            $0.proxyClient.tunneledHosts = { TunneledHostReport() }
            $0.proxyClient.clientCertificates = { [] }
        }
        store.exhaustivity = .off

        await store.send(.viewAppeared)
        await store.receive(\.engineStatusRefreshed) {
            $0.status.socksPort = 9091
            $0.status.reverseProxies = [listening]
        }
        // `capturedCount` is the engine's ring count, and only the engine's: it used to
        // be overwritten locally with the window's row count, so one name meant two
        // different numbers an order of magnitude apart. What the window holds is
        // `capture.allCount`, which is what the sidebar's "All Flows" row reads.
        #expect(store.state.status.capturedCount == 77)
        #expect(store.state.capture.allCount == 0)
    }

    /// An agent opening a port has to appear in the card without the human reopening the
    /// panel. The audit stream is the one signal every write passes through, so it
    /// doubles as the re-sync trigger (as `BreakpointsFeature` does).
    @MainActor
    @Test func anAgentsEndpointShowsUpWithoutReopeningThePanel() async {
        let clock = TestClock()
        let store = TestStore(initialState: AppFeature.State()) {
            AppFeature()
        } withDependencies: {
            $0.continuousClock = clock
            $0.proxyClient.status = {
                ProxyStatus(isRunning: true, port: 9090, capturedCount: 0, reverseProxies: [endpoint()])
            }
            $0.proxyClient.rulesState = { RulesState() }
            $0.proxyClient.certificateStatus = { .notGenerated }
            $0.proxyClient.sslScope = { .disabled }
            $0.proxyClient.tunneledHosts = { TunneledHostReport() }
            $0.proxyClient.clientCertificates = { [] }
        }
        store.exhaustivity = .off

        await store.send(.audit(.entryReceived(
            AuditEntry(tool: "create_reverse_proxy", succeeded: true, arguments: "{}", detail: ""))))
        await clock.advance(by: AppFeature.mirrorRefreshDebounce)
        await store.receive(\.engineStatusRefreshed)
        #expect(store.state.status.reverseProxies.count == 1)
    }

    /// The re-read is coalesced, not run per write. `status()` hops onto `FlowStore`
    /// — the actor every capture write queues on — so an agent writing rules in a
    /// loop must not put one of those behind each of them.
    ///
    /// This used to be enforced by an allowlist naming the two reverse-proxy tools,
    /// which meant a rule write refreshed *nothing* and the rules panel silently
    /// disagreed with the engine until the surface was reopened. A trailing window
    /// gets the cost without the staleness, and with no list to keep in step.
    @MainActor
    @Test func aBurstOfAgentWritesCostsOneRefresh() async {
        let clock = TestClock()
        let statusCalls = LockIsolated(0)
        let store = TestStore(initialState: AppFeature.State()) {
            AppFeature()
        } withDependencies: {
            $0.continuousClock = clock
            $0.proxyClient.status = {
                statusCalls.withValue { $0 += 1 }
                return ProxyStatus(isRunning: true, port: 9090, capturedCount: 0)
            }
            $0.proxyClient.rulesState = { RulesState() }
            $0.proxyClient.certificateStatus = { .notGenerated }
            $0.proxyClient.sslScope = { .disabled }
            $0.proxyClient.tunneledHosts = { TunneledHostReport() }
            $0.proxyClient.clientCertificates = { [] }
        }
        store.exhaustivity = .off

        for _ in 0..<20 {
            await store.send(.audit(.entryReceived(
                AuditEntry(tool: "set_rule", succeeded: true, arguments: "{}", detail: ""))))
        }
        await clock.advance(by: AppFeature.mirrorRefreshDebounce)
        await store.receive(\.engineStatusRefreshed)
        #expect(statusCalls.value == 1, "twenty rule writes must not cost twenty status reads")
    }
}
