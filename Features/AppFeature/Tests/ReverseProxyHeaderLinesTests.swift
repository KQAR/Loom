import Testing
import Foundation
import ComposableArchitecture
import LoomSharedModels
@testable import AppFeature

/// The console header's reverse-proxy lines. Derivation is tested rather than the
/// view, because the case that justifies showing them at all — an endpoint whose port
/// didn't bind — is the one nobody reproduces on demand while looking at a preview.
@Suite struct ReverseProxyHeaderLinesTests {
    private func status(
        port: Int = 9200, upstream: String = "https://api.github.com",
        bound: Int? = 9200, error: String? = nil, label: String? = nil,
        createdAt: Date = Date(timeIntervalSince1970: 1_000)
    ) -> ReverseProxyStatus {
        ReverseProxyStatus(
            endpoint: ReverseProxyEndpoint(
                requestedPort: port, upstream: upstream, label: label, createdAt: createdAt),
            boundPort: bound, error: error
        )
    }

    @Test func noEndpointsDrawNothing() {
        let result = ReverseProxyHeaderLines.lines(for: [])
        #expect(result.lines.isEmpty)
        #expect(result.hidden == 0)
    }

    @Test func aListeningEndpointReadsAsPortForwardsToHost() throws {
        let line = try #require(ReverseProxyHeaderLines.lines(for: [status()]).lines.first)
        #expect(line.text == ":9200 → api.github.com")
        #expect(line.isListening)
        // The scheme and path are in the tooltip, not the line: the console is 300pt
        // wide and the host is what identifies the endpoint.
        #expect(line.help.contains("https://api.github.com"))
    }

    @Test func aLabelIsAppendedSoTwoEndpointsToOneHostAreTellableApart() throws {
        let lines = ReverseProxyHeaderLines.lines(for: [
            status(port: 9200, bound: 9200, label: "checkout"),
            status(port: 9201, bound: 9201, label: "search", createdAt: Date(timeIntervalSince1970: 2_000)),
        ]).lines
        #expect(lines.map(\.text) == [":9200 → api.github.com checkout", ":9201 → api.github.com search"])
    }

    // MARK: The case this exists for

    @Test func aFailedBindIsMarkedAndCarriesTheReason() throws {
        let line = try #require(ReverseProxyHeaderLines.lines(for: [
            status(bound: nil, error: "could not listen on port 9200: Address already in use"),
        ]).lines.first)
        #expect(line.text == ":9200 ✕ api.github.com")
        #expect(!line.isListening)
        #expect(line.help.contains("Address already in use"))
        // What the human actually needs to connect it to: the symptom their client shows.
        #expect(line.help.contains("connection refused"))
    }

    /// When it isn't listening there is no bound port, so the *requested* one is shown —
    /// that is the number written in a dev server's config, and therefore the one the
    /// human recognizes.
    @Test func aFailedBindShowsThePortThatWasAskedFor() throws {
        let line = try #require(ReverseProxyHeaderLines.lines(for: [
            status(port: 9345, bound: nil, error: "boom"),
        ]).lines.first)
        #expect(line.text.hasPrefix(":9345 "))
    }

    @Test func faultsSortAboveListeningEndpoints() {
        let lines = ReverseProxyHeaderLines.lines(for: [
            status(port: 9200, bound: 9200, createdAt: Date(timeIntervalSince1970: 1_000)),
            status(port: 9201, bound: nil, error: "taken", createdAt: Date(timeIntervalSince1970: 2_000)),
        ]).lines
        #expect(lines.first?.isListening == false, "the fault must not sit below healthy endpoints")
    }

    // MARK: Bounded, and honest about it

    @Test func moreEndpointsThanFitCollapseIntoACount() {
        let many = (0 ..< 6).map {
            status(port: 9200 + $0, bound: 9200 + $0, createdAt: Date(timeIntervalSince1970: Double(1_000 + $0)))
        }
        let result = ReverseProxyHeaderLines.lines(for: many)
        #expect(result.lines.count == ReverseProxyHeaderLines.visibleLimit)
        #expect(result.hidden == 6 - ReverseProxyHeaderLines.visibleLimit)
    }

    /// If truncation ever hides something it must not be the fault — an endpoint that
    /// isn't listening is the only line here worth its vertical space.
    @Test func truncationNeverHidesAFault() {
        var endpoints = (0 ..< 5).map {
            status(port: 9200 + $0, bound: 9200 + $0, createdAt: Date(timeIntervalSince1970: Double(1_000 + $0)))
        }
        endpoints.append(status(port: 9500, bound: nil, error: "taken", createdAt: Date(timeIntervalSince1970: 9_999)))
        let result = ReverseProxyHeaderLines.lines(for: endpoints)
        #expect(result.lines.contains { !$0.isListening })
        #expect(result.hidden > 0)
    }

    @Test func anUnparseableUpstreamFallsBackToTheRawStringRatherThanBlank() throws {
        // A hand-edited config file can hold anything; a blank line would be worse
        // than an ugly one.
        let line = try #require(ReverseProxyHeaderLines.lines(for: [status(upstream: "not a url")]).lines.first)
        #expect(line.text.contains("not a url"))
    }

    // MARK: The plumbing that makes the lines reachable at all

    /// `state.status` is maintained locally (the toggle owns `isRunning`, the flow
    /// list owns `capturedCount`), and nothing used to read the engine's own copy —
    /// so `socksPort` and `reverseProxies` were always empty and the header's second line,
    /// which DESIGN.md draws, could never render. Opening the panel now re-reads them.
    @MainActor
    @Test func openingThePanelReadsTheEnginesListenerFacts() async {
        let endpoint = ReverseProxyStatus(
            endpoint: ReverseProxyEndpoint(requestedPort: 9200, upstream: "https://api.github.com"),
            boundPort: 9200
        )
        let store = TestStore(initialState: AppFeature.State()) {
            AppFeature()
        } withDependencies: {
            $0.proxyClient.status = {
                ProxyStatus(
                    isRunning: true, port: 9090, capturedCount: 77, socksPort: 9091,
                    reverseProxies: [endpoint]
                )
            }
            // `viewAppeared` also re-syncs the other children and runs the once-a-day
            // update probe. Stubbed rather than asserted — the listener re-read is what
            // is under test, and `exhaustivity = .off` ignores their state changes but
            // not their unimplemented dependencies.
            $0.updaterClient.checkInBackgroundIfDue = {}
            $0.privilegedHelperClient.systemProxySnapshot = { SystemProxySnapshot() }
            $0.proxyClient.rulesState = { RulesState() }
            $0.proxyClient.armedBreakpoints = { [] }
            $0.proxyClient.pendingBreakpoints = { [] }
            $0.proxyClient.certificateStatus = { .notGenerated }
            $0.proxyClient.sslScope = { .disabled }
            $0.proxyClient.clientCertificates = { [] }
        }
        store.exhaustivity = .off

        await store.send(.viewAppeared)
        await store.receive(\.engineStatusRefreshed) {
            $0.status.socksPort = 9091
            $0.status.reverseProxies = [endpoint]
        }
        // Merged, not assigned: the engine's flow count must not overwrite the
        // window's own bounded list count, which is what "N flows" means.
        #expect(store.state.status.capturedCount == 0)
    }

    /// An agent opening a port has to appear in the header without the human
    /// reopening the panel. The audit stream is the one signal every write passes
    /// through, so it doubles as the re-sync trigger (as `BreakpointsFeature` does).
    @MainActor
    @Test func anAgentsEndpointShowsUpWithoutReopeningThePanel() async {
        let store = TestStore(initialState: AppFeature.State()) {
            AppFeature()
        } withDependencies: {
            $0.proxyClient.status = {
                ProxyStatus(isRunning: true, port: 9090, capturedCount: 0, reverseProxies: [
                    ReverseProxyStatus(
                        endpoint: ReverseProxyEndpoint(requestedPort: 9200, upstream: "https://api.github.com"),
                        boundPort: 9200
                    ),
                ])
            }
        }
        store.exhaustivity = .off

        await store.send(.auditEntryReceived(AuditEntry(tool: "create_reverse_proxy", succeeded: true, arguments: "{}", detail: "")))
        await store.receive(\.engineStatusRefreshed)
        #expect(store.state.status.reverseProxies.count == 1)
    }

    /// …but not on every write. A rule edit changes no port, and re-reading the engine
    /// on each one would put a status call behind every agent action.
    @MainActor
    @Test func anUnrelatedWriteDoesNotRefetchTheStatus() async {
        let store = TestStore(initialState: AppFeature.State()) {
            AppFeature()
        } withDependencies: {
            $0.proxyClient.status = {
                Issue.record("a rule write must not re-read the listener state")
                return ProxyStatus(isRunning: true, port: 9090, capturedCount: 0)
            }
        }
        store.exhaustivity = .off
        await store.send(.auditEntryReceived(AuditEntry(tool: "set_rule", succeeded: true, arguments: "{}", detail: "")))
    }
}
