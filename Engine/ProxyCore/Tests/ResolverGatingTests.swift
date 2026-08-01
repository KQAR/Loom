import Testing
@testable import LoomProxyCore
import LoomSharedModels
import Foundation

/// Forwarding waits for the libproc resolver only when something in the chain
/// actually matches on the source app — `UpstreamForwarding.requiresSourceAppResolution`.
/// Get it wrong in one direction and every request's TTFB carries the resolver's
/// worst case (a serialized pid/fd sweep); wrong in the other and an app-scoped
/// rule silently fails closed against the nil app it was never given.
///
/// The companion invariant lives in `FlowStore`: on the concurrent path the
/// resolver backfills attribution *while the exchange runs*, so a landed answer
/// must survive the relay's later sourceApp-nil upserts, and the backfill must
/// not clobber an outcome recorded meanwhile.
@Suite struct ResolverGatingTests {
    private struct StubUpstream: UpstreamForwarding {
        func forward(method: String, url: URL, headers: [HeaderPair], body: Data?) async throws -> ForwardResult {
            ForwardResult(statusCode: 200, headers: [], body: Data())
        }
    }

    private func ruleForwarder(_ rules: [TrafficRule], enabled: Bool = true) -> RuleApplyingForwarder {
        RuleApplyingForwarder(
            base: StubUpstream(),
            rules: RulesConfig(state: RulesState(enabled: enabled, rules: rules), fileURL: nil)
        )
    }

    private func rule(_ name: String, match: RuleMatch, isEnabled: Bool = true) -> TrafficRule {
        TrafficRule(
            name: name, isEnabled: isEnabled, match: match,
            actions: RuleActions(rewriteResponse: ResponseRewriteAction(statusCode: 503))
        )
    }

    // MARK: Rules

    @Test func appScopedEnabledRule_requiresResolution() {
        let scoped = rule("scoped", match: RuleMatch(urlPattern: "*", sourceApp: "com.example.MyApp"))
        #expect(ruleForwarder([scoped]).requiresSourceAppResolution)
    }

    @Test func unscopedDisabledOrGloballyOffRules_doNot() {
        let plain = rule("plain", match: RuleMatch(urlPattern: "*"))
        let scoped = rule("scoped", match: RuleMatch(urlPattern: "*", sourceApp: "myapp"))
        let scopedOff = rule("scoped-off", match: RuleMatch(urlPattern: "*", sourceApp: "myapp"), isEnabled: false)
        let deviceScoped = rule("device", match: RuleMatch(urlPattern: "*", deviceIP: "192.168.1.9"))

        #expect(!ruleForwarder([plain]).requiresSourceAppResolution)
        #expect(!ruleForwarder([scopedOff]).requiresSourceAppResolution,
                "a disabled rule must not hold up forwarding")
        #expect(!ruleForwarder([scoped], enabled: false).requiresSourceAppResolution,
                "the global rules toggle wins")
        #expect(!ruleForwarder([deviceScoped]).requiresSourceAppResolution,
                "device scoping needs no resolver — the device is known from the connection")
    }

    // MARK: Breakpoints

    @Test func appScopedArmedBreakpoint_requiresResolution_untilDisarmed() {
        let store = BreakpointStore()
        let forwarder = BreakpointForwarder(base: StubUpstream(), store: store)
        #expect(!forwarder.requiresSourceAppResolution)

        let scoped = Breakpoint(match: RuleMatch(urlPattern: "*", sourceApp: "myapp"))
        store.arm(Breakpoint(match: RuleMatch(urlPattern: "*")))
        #expect(!forwarder.requiresSourceAppResolution, "an unscoped breakpoint doesn't need the resolver")
        store.arm(scoped)
        #expect(forwarder.requiresSourceAppResolution)
        _ = store.disarm(id: scoped.id)
        #expect(!forwarder.requiresSourceAppResolution)
    }

    @Test func requirementPropagatesThroughTheDecoratorChain() {
        let scoped = rule("scoped", match: RuleMatch(urlPattern: "*", sourceApp: "myapp"))
        let chain = BreakpointForwarder(base: ruleForwarder([scoped]), store: BreakpointStore())
        #expect(chain.requiresSourceAppResolution, "an inner forwarder's requirement must surface at the outermost")
    }

    // MARK: FlowStore attribution invariants (the concurrent path's other half)

    private func pendingFlow(id: UUID = UUID()) -> Flow {
        Flow(
            id: id,
            request: CapturedRequest(method: "GET", url: "https://api.test/1", headers: []),
            startedAt: Date(timeIntervalSince1970: 1),
            outcome: .pending
        )
    }

    @Test func upsert_keepsALandedAttribution_againstANilOverwrite() async {
        let store = FlowStore()
        let id = UUID()
        await store.upsert(pendingFlow(id: id))
        await store.attributeSourceApp(id: id, SourceApp(name: "MyApp", bundleID: "com.example.MyApp", pid: 5))

        // The relay's completion upsert carries the sourceApp it knew at start: nil.
        var completed = pendingFlow(id: id)
        completed.outcome = .completed(
            CapturedResponse(statusCode: 200, headers: []),
            at: Date(timeIntervalSince1970: 2)
        )
        await store.upsert(completed)

        let flow = await store.flow(id: id)
        #expect(flow?.sourceApp?.bundleID == "com.example.MyApp",
                "attribution, once known, must survive later sourceApp-nil upserts")
        #expect(flow?.completedAt != nil, "and the completion still landed")
    }

    @Test func attributeSourceApp_mergesWithoutClobberingTheOutcome() async {
        let store = FlowStore()
        let id = UUID()
        var completed = pendingFlow(id: id)
        completed.outcome = .completed(
            CapturedResponse(statusCode: 200, headers: []),
            at: Date(timeIntervalSince1970: 2)
        )
        await store.upsert(completed)

        // The resolver answers after the exchange already completed.
        await store.attributeSourceApp(id: id, SourceApp(name: "MyApp", bundleID: "com.example.MyApp", pid: 5))

        let flow = await store.flow(id: id)
        #expect(flow?.sourceApp?.bundleID == "com.example.MyApp")
        #expect(flow?.statusCode == 200, "the backfill must not overwrite the recorded outcome")
    }

    @Test func attributeSourceApp_neverOverwritesAnExistingAttribution() async {
        let store = FlowStore()
        let id = UUID()
        var flow = pendingFlow(id: id)
        flow.sourceApp = SourceApp(name: "First", bundleID: "com.first", pid: 1)
        await store.upsert(flow)

        await store.attributeSourceApp(id: id, SourceApp(name: "Second", bundleID: "com.second", pid: 2))
        let stored = await store.flow(id: id)
        #expect(stored?.sourceApp?.bundleID == "com.first")
    }
}
