import Foundation
import Testing
@testable import LoomProxyCore
import LoomSharedModels

/// Rules have two stages, and `dropFromCapture` is the second one.
///
/// Every other action changes what the client or the origin sees and is applied in
/// `RuleApplyingForwarder`. This one changes what Loom *keeps*, so it is evaluated at
/// `FlowStore.upsert` — the one call every producer arrives through — with the same
/// matcher, the same list and the same master switch.
@Suite("The capture stage of the rules engine")
struct CaptureStageRuleTests {
    private func dropRule(
        host: String, enabled: Bool = true, group: String? = nil
    ) -> TrafficRule {
        TrafficRule(
            name: "Don't capture \(host)",
            group: group,
            isEnabled: enabled,
            match: RuleMatch(urlPattern: "", hostPattern: host),
            actions: RuleActions(dropFromCapture: true)
        )
    }

    private func flow(_ url: String, id: UUID = UUID(), app: SourceApp? = nil) -> Flow {
        Flow(
            id: id,
            request: CapturedRequest(method: "GET", url: url, headers: []),
            startedAt: Date(timeIntervalSince1970: 0),
            sourceApp: app
        )
    }

    private func store(_ rules: [TrafficRule], enabled: Bool = true) -> FlowStore {
        FlowStore(rules: RulesConfig(
            state: RulesState(enabled: enabled, rules: rules), fileURL: nil
        ))
    }

    /// A rule whose only action is `dropFromCapture` is **not** an empty rule. It
    /// looks like one to anything asking "does this change the request" — which is
    /// what `isEmpty` meant before this action existed — and the validator rejected it
    /// the first time one was created over MCP.
    @Test func aCaptureOnlyRuleIsValid() {
        let rule = TrafficRule(
            name: "Don't capture sentry",
            match: RuleMatch(urlPattern: "*", style: .glob, hostPattern: "sentry.example.test"),
            actions: RuleActions(dropFromCapture: true)
        )
        #expect(rule.actions.isEmpty == false)
        #expect(rule.validationError() == nil)
    }

    @Test func aMatchingExchangeIsNeverStored() async {
        let store = store([dropRule(host: "sentry.example.test")])
        await store.upsert(flow("https://sentry.example.test/envelope"))
        await store.upsert(flow("https://api.example.test/v1"))

        #expect(await store.recent(limit: 10).map { $0.request.url } == ["https://api.example.test/v1"])
        #expect(await store.droppedFlowCount == 1)
    }

    /// **The master switch covers this stage too.** It is the whole reason the action
    /// lives in a rule rather than in a list of its own: one switch, one meaning —
    /// "rules off" is Loom doing nothing special, capture included.
    @Test func theMasterSwitchStopsIt() async {
        let store = store([dropRule(host: "sentry.example.test")], enabled: false)
        await store.upsert(flow("https://sentry.example.test/envelope"))
        #expect(await store.recent(limit: 10).count == 1)
        #expect(await store.droppedFlowCount == 0)
    }

    @Test func aDisabledRuleDropsNothing() async {
        let store = store([dropRule(host: "sentry.example.test", enabled: false)])
        await store.upsert(flow("https://sentry.example.test/envelope"))
        #expect(await store.recent(limit: 10).count == 1)
    }

    /// The count is **per rule**, because a dropped exchange carries no `appliedRules`
    /// — it has no flow — so this counter is the only place a capture rule can be seen
    /// to have done anything.
    @Test func eachRuleCountsItsOwn() async {
        let sentry = dropRule(host: "sentry.example.test")
        let metrics = dropRule(host: "metrics.example.test")
        let store = store([sentry, metrics])
        await store.upsert(flow("https://sentry.example.test/1"))
        await store.upsert(flow("https://sentry.example.test/2"))
        await store.upsert(flow("https://metrics.example.test/1"))

        #expect(await store.droppedCountsByRule[sentry.id] == 2)
        #expect(await store.droppedCountsByRule[metrics.id] == 1)
    }

    /// Per exchange, not per upsert: one exchange upserts several times and a dropped
    /// one is never stored, so every one of those looks like a first sighting.
    @Test func theCountIsPerExchange() async {
        let store = store([dropRule(host: "noisy.test")])
        let id = UUID()
        for _ in 0..<5 { await store.upsert(flow("https://noisy.test/x", id: id)) }
        #expect(await store.droppedFlowCount == 1)
    }

    /// It reaches every producer, `CONNECT` rows and failed interceptions included:
    /// they are flows, and the operator said not to record this host.
    @Test func itAppliesToConnectRowsToo() async {
        let store = store([dropRule(host: "relayed.test")])
        await store.upsert(Flow(
            request: CapturedRequest(method: "CONNECT", url: "https://relayed.test:443", headers: []),
            startedAt: Date(timeIntervalSince1970: 0),
            outcome: .completed(CapturedResponse(statusCode: 200, headers: []), at: Date())
        ))
        #expect(await store.recent(limit: 10).isEmpty)
    }

    /// The full match vocabulary comes for free — the point of making it a rule rather
    /// than a second list of host globs.
    @Test func theWholeMatchVocabularyWorks() async {
        let rule = TrafficRule(
            name: "Don't capture health checks",
            match: RuleMatch(urlPattern: "*/health", style: .glob, methods: ["GET"]),
            actions: RuleActions(dropFromCapture: true)
        )
        let store = store([rule])
        await store.upsert(flow("https://api.test/health"))
        await store.upsert(Flow(
            request: CapturedRequest(method: "POST", url: "https://api.test/health", headers: []),
            startedAt: Date(timeIntervalSince1970: 0)
        ))
        let methods = await store.recent(limit: 10).map { $0.request.method }
        #expect(methods == ["POST"], "the method predicate has to narrow it like it does anywhere else")
    }

    /// A rule with no capture action never reaches this stage, however it matches —
    /// the two stages are separate and a mock must not stop the exchange being kept.
    @Test func anOrdinaryRuleDoesNotDrop() async {
        let mock = TrafficRule(
            name: "Mock", match: RuleMatch(urlPattern: "", hostPattern: "api.test"),
            actions: RuleActions(route: .block)
        )
        let store = store([mock])
        await store.upsert(flow("https://api.test/v1"))
        #expect(await store.recent(limit: 10).count == 1, "block stops the request, not the record")
    }
}
