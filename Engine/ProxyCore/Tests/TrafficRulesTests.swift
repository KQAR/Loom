import XCTest
@testable import ProxyCore
import SharedModels

// MARK: - Matching

final class RuleMatchTests: XCTestCase {
    func test_glob_wholeURLMatch() {
        let match = RuleMatch(urlPattern: "https://api.example.test/*/home*")
        XCTAssertTrue(match.matches(method: "GET", url: "https://api.example.test/v1/home"))
        XCTAssertTrue(match.matches(method: "GET", url: "https://api.example.test/v2/home?x=1"))
        XCTAssertFalse(match.matches(method: "GET", url: "https://api.example.test/v1/other"))
        XCTAssertFalse(match.matches(method: "GET", url: "https://other.test/v1/home"))
    }

    func test_noWildcard_isPrefixMatch() {
        let match = RuleMatch(urlPattern: "https://api.example.test/v1/home")
        XCTAssertTrue(match.matches(method: "GET", url: "https://api.example.test/v1/home"))
        XCTAssertTrue(match.matches(method: "GET", url: "https://api.example.test/v1/home?query=1"),
                      "a query string must not defeat a plain-URL pattern")
        XCTAssertFalse(match.matches(method: "GET", url: "https://api.example.test/v1"))
    }

    func test_regex_unanchoredSearch() {
        let match = RuleMatch(urlPattern: #"/api/cashloan/\w+/home(\?.*)?$"#, isRegex: true)
        XCTAssertTrue(match.matches(method: "GET", url: "https://x.test/api/cashloan/phi/home"))
        XCTAssertTrue(match.matches(method: "GET", url: "https://x.test/api/cashloan/phi/home?a=1"))
        XCTAssertFalse(match.matches(method: "GET", url: "https://x.test/api/cashloan/phi/homeV2"))
    }

    func test_invalidRegex_neverMatches() {
        let match = RuleMatch(urlPattern: "([", isRegex: true)
        XCTAssertFalse(match.matches(method: "GET", url: "https://x.test/(["))
    }

    func test_methodsFilter_caseInsensitive() {
        let match = RuleMatch(urlPattern: "https://x.test*", methods: ["get", "POST"])
        XCTAssertTrue(match.matches(method: "GET", url: "https://x.test/"))
        XCTAssertTrue(match.matches(method: "post", url: "https://x.test/"))
        XCTAssertFalse(match.matches(method: "DELETE", url: "https://x.test/"))
    }
}

// MARK: - Validation

final class TrafficRuleValidationTests: XCTestCase {
    private func rule(_ actions: RuleActions, name: String = "r", pattern: String = "https://x.test*", isRegex: Bool = false) -> TrafficRule {
        TrafficRule(name: name, match: RuleMatch(urlPattern: pattern, isRegex: isRegex), actions: actions)
    }

    func test_valid() {
        XCTAssertNil(rule(RuleActions(route: .block)).validationError())
    }

    func test_rejectsEmptyNameEmptyPatternBadRegexNoActions() {
        XCTAssertNotNil(rule(RuleActions(route: .block), name: "  ").validationError())
        XCTAssertNotNil(rule(RuleActions(route: .block), pattern: "").validationError())
        XCTAssertNotNil(rule(RuleActions(route: .block), pattern: "([", isRegex: true).validationError())
        XCTAssertNotNil(rule(RuleActions()).validationError(), "a rule with no actions must be refused")
    }

    func test_rejectsBadMapRemoteAndNegativeDelay() {
        XCTAssertNotNil(rule(RuleActions(route: .mapRemote(MapRemoteAction(destination: "not a url")))).validationError())
        XCTAssertNil(rule(RuleActions(route: .mapRemote(MapRemoteAction(destination: "http://127.0.0.1:3001")))).validationError())
        XCTAssertNotNil(rule(RuleActions(delayMilliseconds: -1)).validationError())
    }
}

// MARK: - Plan / application semantics

final class RuleEngineTests: XCTestCase {
    private let url = URL(string: "https://api.example.test/v1/home?x=1")!

    private func state(_ rules: TrafficRule..., enabled: Bool = true) -> RulesState {
        RulesState(enabled: enabled, rules: rules)
    }

    private func plan(_ state: RulesState, method: String = "GET", headers: [HeaderPair] = [], body: Data? = nil) -> RuleEngine.RequestPlan {
        RuleEngine.planRequest(state: state, method: method, url: url, headers: headers, body: body)
    }

    func test_masterSwitchOff_appliesNothing() {
        let rule = TrafficRule(name: "block", match: RuleMatch(urlPattern: "*"), actions: RuleActions(route: .block))
        let plan = plan(state(rule, enabled: false))
        XCTAssertNil(plan.shortCircuit)
        XCTAssertTrue(plan.matched.isEmpty)
    }

    func test_disabledRule_isSkipped() {
        var rule = TrafficRule(name: "block", match: RuleMatch(urlPattern: "*"), actions: RuleActions(route: .block))
        rule.isEnabled = false
        XCTAssertNil(plan(state(rule)).shortCircuit)
    }

    func test_requestRewrites_compose_inOrder() {
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

        XCTAssertEqual(plan.method, "POST")
        XCTAssertEqual(plan.headers.count, 1, "cookie removed; the two Authorization sets collapse to one")
        XCTAssertEqual(plan.headers.first?.value, "Bearer b", "the later rule wins")
        XCTAssertEqual(plan.body, Data("{}".utf8))
        XCTAssertEqual(plan.appliedRules.map(\.name), ["auth", "override"])
    }

    func test_mapRemote_swapsOriginKeepsPathAndQuery() {
        let rule = TrafficRule(
            name: "map", match: RuleMatch(urlPattern: "*"),
            actions: RuleActions(route: .mapRemote(MapRemoteAction(destination: "http://127.0.0.1:3001")))
        )
        XCTAssertEqual(plan(state(rule)).url.absoluteString, "http://127.0.0.1:3001/v1/home?x=1")
    }

    func test_shortCircuitPrecedence_blockBeatsMockBeatsLocalFile() {
        let local = TrafficRule(name: "file", match: RuleMatch(urlPattern: "*"),
                                actions: RuleActions(route: .mapLocal(MapLocalAction(path: "/tmp/x.json"))))
        let mock = TrafficRule(name: "mock", match: RuleMatch(urlPattern: "*"),
                               actions: RuleActions(route: .mock(MockResponseAction(statusCode: 200))))
        let block = TrafficRule(name: "block", match: RuleMatch(urlPattern: "*"), actions: RuleActions(route: .block))

        // localFile first, mock later: mock outranks the file.
        if case .mock = plan(state(local, mock)).shortCircuit {} else { XCTFail("mock should outrank mapLocal") }
        // mock first, block later: block wins regardless of order.
        if case .block = plan(state(mock, block)).shortCircuit {} else { XCTFail("block should outrank mock") }
        if case .block = plan(state(block, mock)).shortCircuit {} else { XCTFail("block should stay the winner") }
    }

    func test_requestSubstitutions_applyToURLHeadersBody() {
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
        XCTAssertEqual(plan.url.absoluteString, "https://api.example.test/v1/home?x=2")
        XCTAssertEqual(plan.body, Data("bar baz".utf8))
    }

    func test_responseSubstitutions_regexReplacement() {
        let rule = TrafficRule(
            name: "sub", match: RuleMatch(urlPattern: "*"),
            actions: RuleActions(responseSubstitutions: [
                SubstitutionRule(field: .body, match: #""code":\s*\d+"#, replacement: #""code": 0"#, isRegex: true),
            ])
        )
        let requestPlan = plan(state(rule))
        let base = ForwardResult(statusCode: 200, headers: [], body: Data(#"{"code": 42}"#.utf8))
        let result = RuleEngine.applyResponseRewrites(requestPlan.matched, to: base)
        XCTAssertEqual(String(decoding: result.body, as: UTF8.self), #"{"code": 0}"#)
    }

    func test_mapRemote_dropsHostByDefault_keepsWithFlag() {
        let host = HeaderPair(name: "Host", value: "api.example.test")
        let drop = TrafficRule(
            name: "map", match: RuleMatch(urlPattern: "*"),
            actions: RuleActions(route: .mapRemote(MapRemoteAction(destination: "http://127.0.0.1:3001")))
        )
        let dropped = plan(state(drop), headers: [host])
        XCTAssertFalse(dropped.headers.contains { $0.name.lowercased() == "host" },
                       "Host should be dropped so it follows the mapped origin")

        let keep = TrafficRule(
            name: "map", match: RuleMatch(urlPattern: "*"),
            actions: RuleActions(route: .mapRemote(MapRemoteAction(destination: "http://127.0.0.1:3001", keepHostHeader: true)))
        )
        let kept = plan(state(keep), headers: [host])
        XCTAssertEqual(kept.headers.first { $0.name.lowercased() == "host" }?.value, "api.example.test")
    }

    func test_mapRemote_excludeSkipsRedirect() {
        let rule = TrafficRule(
            name: "map", match: RuleMatch(urlPattern: "*"),
            actions: RuleActions(route: .mapRemote(MapRemoteAction(destination: "http://127.0.0.1:3001", excludePattern: "*/v1/home*")))
        )
        // url is https://api.example.test/v1/home?x=1 → excluded, stays put.
        XCTAssertEqual(plan(state(rule)).url.absoluteString, url.absoluteString)
    }

    func test_delay_largestWins() {
        let slow = TrafficRule(name: "slow", match: RuleMatch(urlPattern: "*"), actions: RuleActions(delayMilliseconds: 300))
        let slower = TrafficRule(name: "slower", match: RuleMatch(urlPattern: "*"), actions: RuleActions(delayMilliseconds: 500))
        XCTAssertEqual(plan(state(slower, slow)).delayMilliseconds, 500)
    }

    func test_responseRewrites_apply_inOrder() {
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

        XCTAssertEqual(result.statusCode, 500)
        XCTAssertEqual(result.body, Data("oops".utf8))
        XCTAssertEqual(result.headers.map(\.name), ["Content-Type", "X-Mock"])
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

final class RuleApplyingForwarderTests: XCTestCase {
    private let url = URL(string: "https://api.example.test/v1/home")!

    private func makeForwarder(_ rules: [TrafficRule], enabled: Bool = true) -> (RuleApplyingForwarder, StubUpstream) {
        let upstream = StubUpstream()
        let config = RulesConfig(state: RulesState(enabled: enabled, rules: rules), fileURL: nil)
        return (RuleApplyingForwarder(base: upstream, rules: config), upstream)
    }

    func test_noRules_passthrough_untouched() async throws {
        let (forwarder, upstream) = makeForwarder([])
        let result = try await forwarder.forward(method: "GET", url: url, headers: [], body: nil)
        XCTAssertEqual(upstream.callCount, 1)
        XCTAssertEqual(result.body, Data("upstream".utf8))
        XCTAssertTrue(result.appliedRules.isEmpty)
    }

    func test_mock_shortCircuits_neverContactsUpstream() async throws {
        let rule = TrafficRule(
            name: "home mock", match: RuleMatch(urlPattern: "*"),
            actions: RuleActions(route: .mock(MockResponseAction(
                statusCode: 200, bodyText: #"{"body":"MOCK"}"#, contentType: "application/json"
            )))
        )
        let (forwarder, upstream) = makeForwarder([rule])
        let result = try await forwarder.forward(method: "GET", url: url, headers: [], body: nil)

        XCTAssertEqual(upstream.callCount, 0, "a mocked exchange must not reach the upstream")
        XCTAssertEqual(result.statusCode, 200)
        XCTAssertEqual(result.body, Data(#"{"body":"MOCK"}"#.utf8))
        XCTAssertEqual(result.headers.first(where: { $0.name.lowercased() == "content-type" })?.value, "application/json")
        XCTAssertEqual(result.appliedRules.map(\.name), ["home mock"])
    }

    func test_block_returns403() async throws {
        let rule = TrafficRule(name: "no analytics", match: RuleMatch(urlPattern: "*"), actions: RuleActions(route: .block))
        let (forwarder, upstream) = makeForwarder([rule])
        let result = try await forwarder.forward(method: "GET", url: url, headers: [], body: nil)

        XCTAssertEqual(upstream.callCount, 0)
        XCTAssertEqual(result.statusCode, 403)
        XCTAssertTrue(String(decoding: result.body, as: UTF8.self).contains("no analytics"))
    }

    func test_rewriteAndMapRemote_reachUpstreamRewritten() async throws {
        let rule = TrafficRule(
            name: "to local", match: RuleMatch(urlPattern: "*"),
            actions: RuleActions(
                route: .mapRemote(MapRemoteAction(destination: "http://127.0.0.1:3001")),
                rewriteRequest: RequestRewriteAction(setHeaders: [HeaderPair(name: "X-Debug", value: "1")])
            )
        )
        let (forwarder, upstream) = makeForwarder([rule])
        let result = try await forwarder.forward(method: "GET", url: url, headers: [], body: nil)

        XCTAssertEqual(upstream.lastURL?.absoluteString, "http://127.0.0.1:3001/v1/home")
        XCTAssertEqual(upstream.lastHeaders.map(\.name), ["X-Debug"])
        XCTAssertEqual(result.appliedRules.map(\.name), ["to local"])
    }

    func test_responseRewrite_appliesToRealUpstreamResponse() async throws {
        let rule = TrafficRule(
            name: "force 503", match: RuleMatch(urlPattern: "*"),
            actions: RuleActions(rewriteResponse: ResponseRewriteAction(statusCode: 503))
        )
        let (forwarder, upstream) = makeForwarder([rule])
        let result = try await forwarder.forward(method: "GET", url: url, headers: [], body: nil)

        XCTAssertEqual(upstream.callCount, 1)
        XCTAssertEqual(result.statusCode, 503)
        XCTAssertEqual(result.body, Data("upstream".utf8), "body untouched when the rewrite only changes status")
    }

    func test_mapLocal_servesFileWithGuessedContentType() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("loom-rule-\(UUID()).json")
        try Data(#"{"mocked":true}"#.utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        let rule = TrafficRule(
            name: "local file", match: RuleMatch(urlPattern: "*"),
            actions: RuleActions(route: .mapLocal(MapLocalAction(path: file.path)))
        )
        let (forwarder, upstream) = makeForwarder([rule])
        let result = try await forwarder.forward(method: "GET", url: url, headers: [], body: nil)

        XCTAssertEqual(upstream.callCount, 0)
        XCTAssertEqual(result.body, Data(#"{"mocked":true}"#.utf8))
        XCTAssertEqual(result.headers.first?.value, "application/json")
    }

    func test_mapLocal_missingFile_honest404() async throws {
        let rule = TrafficRule(
            name: "gone", match: RuleMatch(urlPattern: "*"),
            actions: RuleActions(route: .mapLocal(MapLocalAction(path: "/nonexistent/loom-\(UUID()).json")))
        )
        let (forwarder, _) = makeForwarder([rule])
        let result = try await forwarder.forward(method: "GET", url: url, headers: [], body: nil)
        XCTAssertEqual(result.statusCode, 404)
    }
}

// MARK: - Persistence

final class RulesConfigTests: XCTestCase {
    private var fileURL: URL!

    override func setUp() {
        super.setUp()
        fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("loom-rules-\(UUID())", isDirectory: true)
            .appendingPathComponent("rules.json")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent())
        super.tearDown()
    }

    func test_roundTrip_survivesRelaunch() {
        let rule = TrafficRule(name: "persisted", match: RuleMatch(urlPattern: "*"), actions: RuleActions(route: .block))

        let first = RulesConfig(fileURL: fileURL)
        first.add(rule)
        first.setEnabled(false)

        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path), "rules should be written to disk")

        // A fresh instance over the same file = an app relaunch.
        let second = RulesConfig(fileURL: fileURL)
        XCTAssertEqual(second.snapshot().rules, [rule])
        XCTAssertFalse(second.snapshot().enabled)
    }

    func test_missingFile_startsEmpty() {
        let config = RulesConfig(fileURL: fileURL)
        XCTAssertTrue(config.snapshot().rules.isEmpty)
    }

    func test_setGroupEnabled_togglesOnlyMembers() {
        let config = RulesConfig(fileURL: nil)
        let scenarioA = TrafficRule(name: "a", group: "scenario A", match: RuleMatch(urlPattern: "*"), actions: RuleActions(route: .block))
        let scenarioA2 = TrafficRule(name: "a2", group: "scenario A", match: RuleMatch(urlPattern: "*"), actions: RuleActions(route: .block))
        let ungrouped = TrafficRule(name: "solo", match: RuleMatch(urlPattern: "*"), actions: RuleActions(route: .block))
        config.add(scenarioA)
        config.add(scenarioA2)
        config.add(ungrouped)

        config.setGroupEnabled(group: "scenario A", enabled: false)
        var rules = config.snapshot().rules
        XCTAssertEqual(rules.map(\.isEnabled), [false, false, true], "only group members flip")

        config.setGroupEnabled(group: nil, enabled: false)
        rules = config.snapshot().rules
        XCTAssertEqual(rules.map(\.isEnabled), [false, false, false], "nil batch-toggles the ungrouped rules")
    }

    func test_updateAndDelete_reportMisses() {
        let config = RulesConfig(state: RulesState(), fileURL: nil)
        let rule = TrafficRule(name: "r", match: RuleMatch(urlPattern: "*"), actions: RuleActions(route: .block))
        config.add(rule)

        var renamed = rule
        renamed.name = "renamed"
        XCTAssertTrue(config.update(renamed))
        XCTAssertEqual(config.snapshot().rules.first?.name, "renamed")

        var unknown = rule
        unknown.id = UUID()
        XCTAssertFalse(config.update(unknown))
        XCTAssertFalse(config.delete(id: UUID()))
        XCTAssertTrue(config.delete(id: rule.id))
        XCTAssertTrue(config.snapshot().rules.isEmpty)
    }
}
