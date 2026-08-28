import ComposableArchitecture
import Foundation
import LoomSharedModels
import Testing

@testable import AppFeature

/// The computed projections that drive the sidebar + table, and the parent's own
/// projections of engine state.
///
/// Two halves on purpose: the capture window's projections are pure functions of
/// `flows` + selection on `CaptureFeature.State` (no store needed), and the second half
/// covers what `AppFeature.State` *projects* rather than stores — the setup and
/// reverse-proxy fields filled in from `status`.
@Suite struct StateProjectionTests {
    /// Seed both halves: the rows this window holds, and the counts the engine would
    /// report for them. They used to be one call — `recordFlow` folded the counters —
    /// which is exactly what made every sidebar badge a count of the window rather than
    /// of the capture.
    private func state(_ flows: [Flow], category: FlowCategory? = .all) -> CaptureFeature.State {
        var s = CaptureFeature.State(flows: flows)
        var aggregates = FlowAggregates()
        for flow in flows { aggregates.contribute(flow) }
        s.aggregates = aggregates
        s.selectedCategory = category
        return s
    }

    @Test func displayFlows_all_keepsInsertionOrder() {
        let a = Fixtures.flow(url: "https://a.com/1")
        let b = Fixtures.flow(url: "https://b.com/2")
        let s = state([a, b])
        #expect(s.displayFlows.map(\.id) == [a.id, b.id])
    }

    @Test func displayFlows_errors_matchesStatusOrError() {
        let ok = Fixtures.flow(status: 200)
        let http500 = Fixtures.flow(status: 500)
        let failed = Fixtures.flow(status: nil, responseBody: nil, error: "timeout")
        let s = state([ok, http500, failed], category: .errors)
        #expect(Set(s.displayFlows.map(\.id)) == [http500.id, failed.id])
        #expect(s.errorCount == 2)
    }

    @Test func displayFlows_rulesCategory_isEmpty() {
        // The rules panel replaces the table, so the flow list must be empty.
        let s = state([Fixtures.flow()], category: .rules)
        #expect(s.displayFlows.isEmpty)
    }

    @Test func displayFlows_host_filtersByHost() {
        let a = Fixtures.flow(url: "https://a.com/x")
        let b = Fixtures.flow(url: "https://b.com/y")
        let s = state([a, b], category: .host("b.com"))
        #expect(s.displayFlows.map(\.id) == [b.id])
    }

    @Test func hosts_pinnedFloatToTop_thenAlphabetical() {
        let flows = [
            Fixtures.flow(url: "https://charlie.com/1"),
            Fixtures.flow(url: "https://alpha.com/1"),
            Fixtures.flow(url: "https://bravo.com/1"),
        ]
        var s = state(flows)
        s.pinnedHosts = ["charlie.com"]
        #expect(s.hosts.map(\.host) == ["charlie.com", "alpha.com", "bravo.com"])
    }

    @Test func hosts_countsPerHost() {
        let flows = [
            Fixtures.flow(url: "https://a.com/1"),
            Fixtures.flow(url: "https://a.com/2"),
            Fixtures.flow(url: "https://b.com/1"),
        ]
        let s = state(flows)
        #expect(s.hosts.first(where: { $0.host == "a.com" })?.count == 2)
        #expect(s.hosts.first(where: { $0.host == "b.com" })?.count == 1)
    }

    @Test func apps_pinnedFloatToTop_thenMostActive() {
        func f(_ bundle: String) -> Flow {
            // Apps hang off the device they ran on now, so an app row only exists
            // once the flow has both halves.
            Fixtures.flow(
                sourceApp: SourceApp(name: bundle, bundleID: bundle, pid: 1),
                sourceDevice: SourceDevice(ip: "127.0.0.1", kind: .local)
            )
        }
        // com.busy has 2, com.quiet + com.pinned have 1 each.
        var s = state([f("com.busy"), f("com.busy"), f("com.quiet"), f("com.pinned")])
        s.pinnedApps = ["com.pinned"]
        let keys = s.apps.map(\.app.groupingKey)
        #expect(keys.first == "com.pinned")       // pinned floats up despite lower count
        #expect(keys.dropFirst().first == "com.busy") // then most-active
    }

    @Test func selectedFlow_resolvesByID() {
        let flow = Fixtures.flow()
        var s = state([flow])
        s.selectedFlowID = flow.id
        #expect(s.selectedFlow?.id == flow.id)
        #expect(s.allCount == 1)
    }

    // MARK: Session display cap (② capacity visibility)

    @Test func recordFlow_underCap_dropsNothing() {
        var s = CaptureFeature.State()
        let flows = (0 ..< 5).map { _ in Fixtures.flow() }
        flows.forEach { s.recordFlow($0) }
        #expect(s.flows.count == 5)
        #expect(s.droppedFlowCount == 0)
    }

    /// Filling the window must stay linear.
    ///
    /// `flows` is a stored property of an `@ObservableState` value, and writing through
    /// it costs work proportional to what it holds — measured at this cap, 690 µs per
    /// insert against 2.6 µs into a plain container. Mutating it once per flow made
    /// filling the window quadratic: 14 s, where building on a local copy and assigning
    /// once is 90 ms. The bound is deliberately loose and stated **per row**
    /// (`WindowPerf`) — this is a guard against the shape coming back, not a benchmark,
    /// it must not fail because CI is busy, and a flat second was a fact about the old
    /// cap rather than about this code.
    @Test func fillingTheWindowIsLinear() {
        let flows = (0 ..< CaptureFeature.State.displayCap).map { _ in Fixtures.flow() }
        var state = CaptureFeature.State()
        let start = Date()
        state.recordFlows(flows)
        let elapsed = Date().timeIntervalSince(start)
        #expect(state.flows.count == CaptureFeature.State.displayCap)
        #expect(elapsed < WindowPerf.fullWindowBudget,
                "filling the window took \(elapsed)s — the per-flow write through observed state is back")
    }

    @Test func recordFlow_overCap_dropsOldestAndCounts() {
        var s = CaptureFeature.State()
        let cap = CaptureFeature.State.displayCap
        let flows = (0 ..< (cap + 3)).map { _ in Fixtures.flow() }
        // Batched: per-flow recording trims the cap on every call, which is O(cap) each
        // and quadratic at this size (see `CaptureFeature.State.recordFlow`).
        s.recordFlows(flows)

        // The trim cuts to `displayCap - trimSlack`, not to the cap, so that the next few
        // hundred batches cost nothing — see `State.trimSlack`. The cap is still a
        // ceiling the window may never exceed.
        let dropped = CaptureFeature.State.trimSlack + 3
        #expect(s.flows.count == cap - CaptureFeature.State.trimSlack, "trimmed a slack's worth below the cap")
        #expect(s.flows.count <= cap, "and never above it")
        #expect(s.droppedFlowCount == dropped, "every dropped row is counted")
        #expect(s.flows.last?.id == flows.last?.id, "newest is retained")
        #expect(s.flows[id: flows[0].id] == nil, "oldest is gone")
        #expect(s.flows.first?.id == flows[dropped].id, "the survivors are the newest, in order")
    }

    @Test func recordFlow_upsertExistingID_doesNotCountAsNew() {
        var s = CaptureFeature.State()
        let flow = Fixtures.flow(status: nil, responseBody: nil) // in-flight
        s.recordFlow(flow)
        s.recordFlow(Fixtures.flow(id: flow.id, status: 200)) // completion re-arrives
        #expect(s.flows.count == 1)
        #expect(s.flows[id: flow.id]?.statusCode == 200)
        #expect(s.droppedFlowCount == 0)
    }

    @Test func recordFlow_droppingSelectedClearsSelection() {
        var s = CaptureFeature.State()
        let first = Fixtures.flow()
        s.recordFlow(first)
        s.selectedFlowID = first.id
        // Push exactly past the cap so `first` (the oldest) is evicted.
        s.recordFlows((0 ..< CaptureFeature.State.displayCap).map { _ in Fixtures.flow() })
        #expect(s.flows[id: first.id] == nil)
        #expect(s.selectedFlowID == nil, "a dropped selection must not dangle")
    }
}

/// The two child states the parent *projects* rather than mirrors: `setup` gets the
/// proxy's port and running state, `reverseProxy` gets the endpoint list. Both are
/// owned by the parent's `status`, and the reason for the projection is that the
/// copies used to be written by hand at every site that changed the source — in
/// step only because three call sites remembered.
@Suite struct ProjectedChildStateTests {
    @Test func reverseProxyEndpoints_comeFromStatus_notFromTheChild() {
        var state = AppFeature.State()
        let listening = ReverseProxyStatus(
            endpoint: ReverseProxyEndpoint(requestedPort: 0, upstream: "https://api.example.test"),
            boundPort: 54_321
        )
        state.status.reverseProxies = [listening]
        #expect(state.reverseProxy.endpoints == [listening])
    }

    /// The projected field is cleared on the way back in rather than merely ignored on
    /// the next read. A stale copy in the backing store is invisible to every view (the
    /// getter overwrites it) but not to `Equatable` — two states agreeing about the
    /// engine would compare unequal over a list neither of them owns, which in a
    /// `TestStore` reads as an unexplained state mismatch.
    @Test func aChildWriteDoesNotLeaveAStaleEndpointCopyBehind() {
        var state = AppFeature.State()
        state.status.reverseProxies = [
            ReverseProxyStatus(
                endpoint: ReverseProxyEndpoint(requestedPort: 9200, upstream: "https://api.example.test"),
                boundPort: 9200
            ),
        ]
        state.reverseProxy.isExpanded = true // a read-modify-write through the projection

        var expected = AppFeature.State()
        expected.status.reverseProxies = state.status.reverseProxies
        expected.reverseProxy.isExpanded = true
        #expect(state.reverseProxyState == expected.reverseProxyState)
        #expect(state.reverseProxyState.endpoints.isEmpty)
        #expect(state.reverseProxy.endpoints.count == 1)
    }

    @Test func setupPortAndRunningState_comeFromStatus() {
        var state = AppFeature.State()
        state.status.port = 9099
        state.status.isRunning = true
        #expect(state.setup.port == 9099)
        #expect(state.setup.proxyRunning)
    }

    // MARK: - displayHost

    // Where the listener is bound, which is the engine's own answer. Reading it off
    // `localIP` advertised a LAN address while the proxy was on loopback — an
    // address that refuses the connection. Deciding on `isLANReachable` fixed that
    // and kept the other half: bound to every interface it printed one of them,
    // which is narrower than the truth and a different fact from the one the chip
    // beside the capture dot is for.

    @Test func displayHost_loopbackBinding_ignoresTheLANAddress() {
        var state = AppFeature.State()
        state.localIP = "192.168.1.42"
        state.status.listenHost = "127.0.0.1"
        #expect(state.displayHost == "127.0.0.1")
    }

    /// A resolved LAN address does not narrow the answer: the listener is answering
    /// on every interface, and naming one of them is a claim the chip isn't making.
    /// What a phone types in is the phone popover's material (`PhoneOnboardingInfo`),
    /// resolved by the engine at publish time.
    @Test func displayHost_lanBinding_saysWildcardEvenWithAnAddressResolved() {
        var state = AppFeature.State()
        state.localIP = "192.168.1.42"
        state.status.listenHost = "0.0.0.0"
        #expect(state.displayHost == "0.0.0.0")
    }

    @Test func displayHost_lanBindingWithNoResolvedAddress_saysWildcard() {
        var state = AppFeature.State()
        state.localIP = nil
        state.status.listenHost = "0.0.0.0"
        #expect(state.displayHost == "0.0.0.0")
    }

    /// The default `ProxyStatus` binds loopback, so a state nobody has told about
    /// the engine must not start out claiming a LAN address.
    @Test func displayHost_defaultState_isLoopback() {
        #expect(AppFeature.State().displayHost == "127.0.0.1")
    }
}
