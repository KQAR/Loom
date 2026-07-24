import Testing
@testable import ProxyCore
import SharedModels
import Foundation

// MARK: - Matching

@Suite struct RuleMatchTests {
    @Test func glob_wholeURLMatch() {
        let match = RuleMatch(urlPattern: "https://api.example.test/*/home*")
        #expect(match.matches(method: "GET", url: "https://api.example.test/v1/home"))
        #expect(match.matches(method: "GET", url: "https://api.example.test/v2/home?x=1"))
        #expect(!match.matches(method: "GET", url: "https://api.example.test/v1/other"))
        #expect(!match.matches(method: "GET", url: "https://other.test/v1/home"))
    }

    @Test func noWildcard_isPrefixMatch() {
        let match = RuleMatch(urlPattern: "https://api.example.test/v1/home")
        #expect(match.matches(method: "GET", url: "https://api.example.test/v1/home"))
        #expect(match.matches(method: "GET", url: "https://api.example.test/v1/home?query=1"),
                "a query string must not defeat a plain-URL pattern")
        #expect(!match.matches(method: "GET", url: "https://api.example.test/v1"))
    }

    @Test func regex_unanchoredSearch() {
        let match = RuleMatch(urlPattern: #"/api/cashloan/\w+/home(\?.*)?$"#, isRegex: true)
        #expect(match.matches(method: "GET", url: "https://x.test/api/cashloan/phi/home"))
        #expect(match.matches(method: "GET", url: "https://x.test/api/cashloan/phi/home?a=1"))
        #expect(!match.matches(method: "GET", url: "https://x.test/api/cashloan/phi/homeV2"))
    }

    @Test func invalidRegex_neverMatches() {
        let match = RuleMatch(urlPattern: "([", isRegex: true)
        #expect(!match.matches(method: "GET", url: "https://x.test/(["))
    }

    @Test func methodsFilter_caseInsensitive() {
        let match = RuleMatch(urlPattern: "https://x.test*", methods: ["get", "POST"])
        #expect(match.matches(method: "GET", url: "https://x.test/"))
        #expect(match.matches(method: "post", url: "https://x.test/"))
        #expect(!match.matches(method: "DELETE", url: "https://x.test/"))
    }
}

// MARK: - Validation

@Suite struct TrafficRuleValidationTests {
    private func rule(_ actions: RuleActions, name: String = "r", pattern: String = "https://x.test*", isRegex: Bool = false) -> TrafficRule {
        TrafficRule(name: name, match: RuleMatch(urlPattern: pattern, isRegex: isRegex), actions: actions)
    }

    @Test func valid() {
        #expect(rule(RuleActions(route: .block)).validationError() == nil)
    }

    @Test func rejectsEmptyNameEmptyPatternBadRegexNoActions() {
        #expect(rule(RuleActions(route: .block), name: "  ").validationError() != nil)
        #expect(rule(RuleActions(route: .block), pattern: "").validationError() != nil)
        #expect(rule(RuleActions(route: .block), pattern: "([", isRegex: true).validationError() != nil)
        #expect(rule(RuleActions()).validationError() != nil, "a rule with no actions must be refused")
    }

    @Test func rejectsBadMapRemoteAndNegativeDelay() {
        #expect(rule(RuleActions(route: .mapRemote(MapRemoteAction(destination: "not a url")))).validationError() != nil)
        #expect(rule(RuleActions(route: .mapRemote(MapRemoteAction(destination: "http://127.0.0.1:3001")))).validationError() == nil)
        #expect(rule(RuleActions(delayMilliseconds: -1)).validationError() != nil)
    }
}

// MARK: - Plan / application semantics

@Suite struct RuleEngineTests {
    private let url = URL(string: "https://api.example.test/v1/home?x=1")!

    private func state(_ rules: TrafficRule..., enabled: Bool = true) -> RulesState {
        RulesState(enabled: enabled, rules: rules)
    }

    private func plan(_ state: RulesState, method: String = "GET", headers: [HeaderPair] = [], body: Data? = nil) -> RuleEngine.RequestPlan {
        RuleEngine.planRequest(state: state, method: method, url: url, headers: headers, body: body)
    }

    @Test func masterSwitchOff_appliesNothing() {
        let rule = TrafficRule(name: "block", match: RuleMatch(urlPattern: "*"), actions: RuleActions(route: .block))
        let plan = plan(state(rule, enabled: false))
        #expect(plan.shortCircuit == nil)
        #expect(plan.matched.isEmpty)
    }

    @Test func disabledRule_isSkipped() {
        var rule = TrafficRule(name: "block", match: RuleMatch(urlPattern: "*"), actions: RuleActions(route: .block))
        rule.isEnabled = false
        #expect(plan(state(rule)).shortCircuit == nil)
    }

    @Test func requestRewrites_compose_inOrder() {
        let first = TrafficRule(
            name: "auth", match: RuleMatch(urlPattern: "*"),
            actions: RuleActions(rewriteRequest: RequestRewriteAction(setHeaders: [HeaderPair(name: "Authorization", value: "Bearer a")]))
        )
        let second = TrafficRule(
            name: "override", match: RuleMatch(urlPattern: "*"),
            actions: RuleActions(rewriteRequest: RequestRewriteAction(
                method: "post",
                setHeaders: [HeaderPair(name: "authorization", value: "Bearer b")],
                removeHeaders: ["Cookie"],
                bodyText: "{}"
            ))
        )
        let plan = plan(state(first, second), headers: [HeaderPair(name: "Cookie", value: "session=1")])

        #expect(plan.method == "POST")
        #expect(plan.headers.count == 1, "cookie removed; the two Authorization sets collapse to one")
        #expect(plan.headers.first?.value == "Bearer b", "the later rule wins")
        #expect(plan.body == Data("{}".utf8))
        #expect(plan.appliedRules.map(\.name) == ["auth", "override"])
    }

    @Test func mapRemote_swapsOriginKeepsPathAndQuery() {
        let rule = TrafficRule(
            name: "map", match: RuleMatch(urlPattern: "*"),
            actions: RuleActions(route: .mapRemote(MapRemoteAction(destination: "http://127.0.0.1:3001")))
        )
        #expect(plan(state(rule)).url.absoluteString == "http://127.0.0.1:3001/v1/home?x=1")
    }

    @Test func shortCircuitPrecedence_blockBeatsMockBeatsLocalFile() {
        let local = TrafficRule(name: "file", match: RuleMatch(urlPattern: "*"),
                                actions: RuleActions(route: .mapLocal(MapLocalAction(path: "/tmp/x.json"))))
        let mock = TrafficRule(name: "mock", match: RuleMatch(urlPattern: "*"),
                               actions: RuleActions(route: .mock(MockResponseAction(statusCode: 200))))
        let block = TrafficRule(name: "block", match: RuleMatch(urlPattern: "*"), actions: RuleActions(route: .block))

        // localFile first, mock later: mock outranks the file.
        if case .mock = plan(state(local, mock)).shortCircuit {} else { Issue.record("mock should outrank mapLocal") }
        // mock first, block later: block wins regardless of order.
        if case .block = plan(state(mock, block)).shortCircuit {} else { Issue.record("block should outrank mock") }
        if case .block = plan(state(block, mock)).shortCircuit {} else { Issue.record("block should stay the winner") }
    }

    @Test func requestSubstitutions_applyToURLHeadersBody() {
        let rule = TrafficRule(
            name: "sub", match: RuleMatch(urlPattern: "*"),
            actions: RuleActions(requestSubstitutions: [
                SubstitutionRule(field: .url, match: "x=1", replacement: "x=2"),
                SubstitutionRule(field: .body, match: "foo", replacement: "bar"),
            ])
        )
        let plan = RuleEngine.planRequest(
            state: state(rule), method: "GET", url: url, headers: [], body: Data("foo baz".utf8)
        )
        #expect(plan.url.absoluteString == "https://api.example.test/v1/home?x=2")
        #expect(plan.body == Data("bar baz".utf8))
    }

    @Test func responseSubstitutions_regexReplacement() {
        let rule = TrafficRule(
            name: "sub", match: RuleMatch(urlPattern: "*"),
            actions: RuleActions(responseSubstitutions: [
                SubstitutionRule(field: .body, match: #""code":\s*\d+"#, replacement: #""code": 0"#, isRegex: true),
            ])
        )
        let requestPlan = plan(state(rule))
        let base = ForwardResult(statusCode: 200, headers: [], body: Data(#"{"code": 42}"#.utf8))
        let result = RuleEngine.applyResponseRewrites(requestPlan.matched, to: base)
        #expect(String(decoding: result.body, as: UTF8.self) == #"{"code": 0}"#)
    }

    @Test func mapRemote_dropsHostByDefault_keepsWithFlag() {
        let host = HeaderPair(name: "Host", value: "api.example.test")
        let drop = TrafficRule(
            name: "map", match: RuleMatch(urlPattern: "*"),
            actions: RuleActions(route: .mapRemote(MapRemoteAction(destination: "http://127.0.0.1:3001")))
        )
        let dropped = plan(state(drop), headers: [host])
        #expect(!dropped.headers.contains { $0.name.lowercased() == "host" },
                "Host should be dropped so it follows the mapped origin")

        let keep = TrafficRule(
            name: "map", match: RuleMatch(urlPattern: "*"),
            actions: RuleActions(route: .mapRemote(MapRemoteAction(destination: "http://127.0.0.1:3001", keepHostHeader: true)))
        )
        let kept = plan(state(keep), headers: [host])
        #expect(kept.headers.first { $0.name.lowercased() == "host" }?.value == "api.example.test")
    }

    @Test func mapRemote_excludeSkipsRedirect() {
        let rule = TrafficRule(
            name: "map", match: RuleMatch(urlPattern: "*"),
            actions: RuleActions(route: .mapRemote(MapRemoteAction(destination: "http://127.0.0.1:3001", excludePattern: "*/v1/home*")))
        )
        // url is https://api.example.test/v1/home?x=1 → excluded, stays put.
        #expect(plan(state(rule)).url.absoluteString == url.absoluteString)
    }

    @Test func delay_largestWins() {
        let slow = TrafficRule(name: "slow", match: RuleMatch(urlPattern: "*"), actions: RuleActions(delayMilliseconds: 300))
        let slower = TrafficRule(name: "slower", match: RuleMatch(urlPattern: "*"), actions: RuleActions(delayMilliseconds: 500))
        #expect(plan(state(slower, slow)).delayMilliseconds == 500)
    }

    @Test func responseRewrites_apply_inOrder() {
        let first = TrafficRule(
            name: "status", match: RuleMatch(urlPattern: "*"),
            actions: RuleActions(rewriteResponse: ResponseRewriteAction(statusCode: 500))
        )
        let second = TrafficRule(
            name: "body", match: RuleMatch(urlPattern: "*"),
            actions: RuleActions(rewriteResponse: ResponseRewriteAction(
                setHeaders: [HeaderPair(name: "X-Mock", value: "1")], bodyText: "oops"
            ))
        )
        let plan = plan(state(first, second))
        let base = ForwardResult(statusCode: 200, headers: [HeaderPair(name: "Content-Type", value: "application/json")], body: Data("{}".utf8))
        let result = RuleEngine.applyResponseRewrites(plan.matched, to: base)

        #expect(result.statusCode == 500)
        #expect(result.body == Data("oops".utf8))
        #expect(result.headers.map(\.name) == ["Content-Type", "X-Mock"])
    }
}

// MARK: - Forwarder decorator

private final class StubUpstream: UpstreamForwarding, @unchecked Sendable {
    var callCount = 0
    var lastMethod: String?
    var lastURL: URL?
    var lastHeaders: [HeaderPair] = []
    var lastBody: Data?
    var result = ForwardResult(statusCode: 200, headers: [], body: Data("upstream".utf8))

    func forward(method: String, url: URL, headers: [HeaderPair], body: Data?) async throws -> ForwardResult {
        callCount += 1
        lastMethod = method
        lastURL = url
        lastHeaders = headers
        lastBody = body
        return result
    }
}

@Suite struct RuleApplyingForwarderTests {
    private let url = URL(string: "https://api.example.test/v1/home")!

    private func makeForwarder(_ rules: [TrafficRule], enabled: Bool = true) -> (RuleApplyingForwarder, StubUpstream) {
        let upstream = StubUpstream()
        let config = RulesConfig(state: RulesState(enabled: enabled, rules: rules), fileURL: nil)
        return (RuleApplyingForwarder(base: upstream, rules: config), upstream)
    }

    @Test func noRules_passthrough_untouched() async throws {
        let (forwarder, upstream) = makeForwarder([])
        let result = try await forwarder.forward(method: "GET", url: url, headers: [], body: nil)
        #expect(upstream.callCount == 1)
        #expect(result.body == Data("upstream".utf8))
        #expect(result.appliedRules.isEmpty)
    }

    @Test func mock_shortCircuits_neverContactsUpstream() async throws {
        let rule = TrafficRule(
            name: "home mock", match: RuleMatch(urlPattern: "*"),
            actions: RuleActions(route: .mock(MockResponseAction(
                statusCode: 200, bodyText: #"{"body":"MOCK"}"#, contentType: "application/json"
            )))
        )
        let (forwarder, upstream) = makeForwarder([rule])
        let result = try await forwarder.forward(method: "GET", url: url, headers: [], body: nil)

        #expect(upstream.callCount == 0, "a mocked exchange must not reach the upstream")
        #expect(result.statusCode == 200)
        #expect(result.body == Data(#"{"body":"MOCK"}"#.utf8))
        #expect(result.headers.first(where: { $0.name.lowercased() == "content-type" })?.value == "application/json")
        #expect(result.appliedRules.map(\.name) == ["home mock"])
    }

    @Test func block_returns403() async throws {
        let rule = TrafficRule(name: "no analytics", match: RuleMatch(urlPattern: "*"), actions: RuleActions(route: .block))
        let (forwarder, upstream) = makeForwarder([rule])
        let result = try await forwarder.forward(method: "GET", url: url, headers: [], body: nil)

        #expect(upstream.callCount == 0)
        #expect(result.statusCode == 403)
        #expect(String(decoding: result.body, as: UTF8.self).contains("no analytics"))
    }

    @Test func rewriteAndMapRemote_reachUpstreamRewritten() async throws {
        let rule = TrafficRule(
            name: "to local", match: RuleMatch(urlPattern: "*"),
            actions: RuleActions(
                route: .mapRemote(MapRemoteAction(destination: "http://127.0.0.1:3001")),
                rewriteRequest: RequestRewriteAction(setHeaders: [HeaderPair(name: "X-Debug", value: "1")])
            )
        )
        let (forwarder, upstream) = makeForwarder([rule])
        let result = try await forwarder.forward(method: "GET", url: url, headers: [], body: nil)

        #expect(upstream.lastURL?.absoluteString == "http://127.0.0.1:3001/v1/home")
        #expect(upstream.lastHeaders.map(\.name) == ["X-Debug"])
        #expect(result.appliedRules.map(\.name) == ["to local"])
    }

    @Test func responseRewrite_appliesToRealUpstreamResponse() async throws {
        let rule = TrafficRule(
            name: "force 503", match: RuleMatch(urlPattern: "*"),
            actions: RuleActions(rewriteResponse: ResponseRewriteAction(statusCode: 503))
        )
        let (forwarder, upstream) = makeForwarder([rule])
        let result = try await forwarder.forward(method: "GET", url: url, headers: [], body: nil)

        #expect(upstream.callCount == 1)
        #expect(result.statusCode == 503)
        #expect(result.body == Data("upstream".utf8), "body untouched when the rewrite only changes status")
    }

    @Test func mapLocal_servesFileWithGuessedContentType() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("loom-rule-\(UUID()).json")
        try Data(#"{"mocked":true}"#.utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        let rule = TrafficRule(
            name: "local file", match: RuleMatch(urlPattern: "*"),
            actions: RuleActions(route: .mapLocal(MapLocalAction(path: file.path)))
        )
        let (forwarder, upstream) = makeForwarder([rule])
        let result = try await forwarder.forward(method: "GET", url: url, headers: [], body: nil)

        #expect(upstream.callCount == 0)
        #expect(result.body == Data(#"{"mocked":true}"#.utf8))
        #expect(result.headers.first?.value == "application/json")
    }

    @Test func mapLocal_missingFile_honest404() async throws {
        let rule = TrafficRule(
            name: "gone", match: RuleMatch(urlPattern: "*"),
            actions: RuleActions(route: .mapLocal(MapLocalAction(path: "/nonexistent/loom-\(UUID()).json")))
        )
        let (forwarder, _) = makeForwarder([rule])
        let result = try await forwarder.forward(method: "GET", url: url, headers: [], body: nil)
        #expect(result.statusCode == 404)
    }
}

// MARK: - Persistence

@Suite final class RulesConfigTests {
    private let fileURL: URL

    init() {
        fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("loom-rules-\(UUID())", isDirectory: true)
            .appendingPathComponent("rules.json")
    }

    deinit {
        try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent())
    }

    @Test func roundTrip_survivesRelaunch() {
        let rule = TrafficRule(name: "persisted", match: RuleMatch(urlPattern: "*"), actions: RuleActions(route: .block))

        let first = RulesConfig(fileURL: fileURL)
        first.add(rule)
        first.setEnabled(false)

        #expect(FileManager.default.fileExists(atPath: fileURL.path), "rules should be written to disk")

        // A fresh instance over the same file = an app relaunch.
        let second = RulesConfig(fileURL: fileURL)
        #expect(second.snapshot().rules == [rule])
        #expect(!second.snapshot().enabled)
    }

    @Test func missingFile_startsEmpty() {
        let config = RulesConfig(fileURL: fileURL)
        #expect(config.snapshot().rules.isEmpty)
    }

    @Test func setGroupEnabled_togglesOnlyMembers() {
        let config = RulesConfig(fileURL: nil)
        let scenarioA = TrafficRule(name: "a", group: "scenario A", match: RuleMatch(urlPattern: "*"), actions: RuleActions(route: .block))
        let scenarioA2 = TrafficRule(name: "a2", group: "scenario A", match: RuleMatch(urlPattern: "*"), actions: RuleActions(route: .block))
        let ungrouped = TrafficRule(name: "solo", match: RuleMatch(urlPattern: "*"), actions: RuleActions(route: .block))
        config.add(scenarioA)
        config.add(scenarioA2)
        config.add(ungrouped)

        config.setGroupEnabled(group: "scenario A", enabled: false)
        var rules = config.snapshot().rules
        #expect(rules.map(\.isEnabled) == [false, false, true], "only group members flip")

        config.setGroupEnabled(group: nil, enabled: false)
        rules = config.snapshot().rules
        #expect(rules.map(\.isEnabled) == [false, false, false], "nil batch-toggles the ungrouped rules")
    }

    @Test func updateAndDelete_reportMisses() {
        let config = RulesConfig(state: RulesState(), fileURL: nil)
        let rule = TrafficRule(name: "r", match: RuleMatch(urlPattern: "*"), actions: RuleActions(route: .block))
        config.add(rule)

        var renamed = rule
        renamed.name = "renamed"
        #expect(config.update(renamed))
        #expect(config.snapshot().rules.first?.name == "renamed")

        var unknown = rule
        unknown.id = UUID()
        #expect(!config.update(unknown))
        #expect(!config.delete(id: UUID()))
        #expect(config.delete(id: rule.id))
        #expect(config.snapshot().rules.isEmpty)
    }
}
