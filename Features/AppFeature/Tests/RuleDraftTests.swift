import Foundation
import LoomSharedModels
import Testing

@testable import AppFeature

/// `RuleDraft` is the flattened, editable mirror of a `TrafficRule`. Its contract
/// is that editing a rule the UI doesn't fully surface (mapLocal, rewriteResponse,
/// multi-method matches, comments) never silently drops those fields on save.
@Suite struct RuleDraftTests {
    private func built(_ rule: TrafficRule) -> TrafficRule {
        switch RuleDraft(rule: rule).build() {
        case let .success(r): return r
        case let .failure(e): Issue.record("build failed: \(e.message)"); return rule
        }
    }

    @Test func block_roundTripsExactly() {
        let rule = Fixtures.rule(name: "Block home", route: .block)
        #expect(built(rule) == rule)
    }

    @Test func mock_preservesStatusBodyAndCarriedHeaders() {
        let mock = MockResponseAction(
            statusCode: 201,
            headers: [HeaderPair(name: "X-Debug", value: "1")], // MCP-set, editor doesn't surface
            bodyText: #"{"ok":true}"#,
            contentType: "application/json"
        )
        let rule = Fixtures.rule(route: .mock(mock))
        guard case let .mock(out) = built(rule).actions.route else {
            Issue.record("expected a mock route")
            return
        }
        #expect(out.statusCode == 201)
        #expect(out.bodyText == #"{"ok":true}"#)
        #expect(out.contentType == "application/json")
        #expect(out.headers == [HeaderPair(name: "X-Debug", value: "1")])
    }

    @Test func mapLocal_carriedThroughUnsurfacedByEditor() {
        let local = MapLocalAction(path: "/tmp/fixture.json", statusCode: 200, contentType: "application/json")
        let rule = Fixtures.rule(route: .mapLocal(local))
        #expect(built(rule).actions.route == .mapLocal(local))
    }

    @Test func mapRemote_roundTrips() {
        let remote = MapRemoteAction(destination: "http://127.0.0.1:3001", keepHostHeader: true)
        let rule = Fixtures.rule(route: .mapRemote(remote))
        #expect(built(rule).actions.route == .mapRemote(remote))
    }

    @Test func rewriteResponse_carriedThrough() {
        var rule = Fixtures.rule(route: .passthrough)
        let rewrite = ResponseRewriteAction(statusCode: 418, bodyText: "teapot")
        rule.actions.rewriteResponse = rewrite
        #expect(built(rule).actions.rewriteResponse == rewrite)
    }

    @Test func comment_preservedThoughEditorHidesIt() {
        var rule = Fixtures.rule(route: .block)
        rule.comment = "authored via MCP"
        #expect(built(rule).comment == "authored via MCP")
    }

    @Test func multiMethod_matchPreservedWhenUntouched() {
        let rule = Fixtures.rule(methods: ["GET", "HEAD"], route: .block)
        // Editor's single-select dropdown shows the first method but must keep the set.
        #expect(built(rule).match.methods == ["GET", "HEAD"])
    }

    @Test func delay_roundTrips() {
        var rule = Fixtures.rule(route: .passthrough)
        rule.actions.delayMilliseconds = 250
        #expect(built(rule).actions.delayMilliseconds == 250)
    }

    @Test func substitutions_dropEmptyRowsOnBuild() {
        var rule = Fixtures.rule(route: .passthrough)
        rule.actions.requestSubstitutions = [
            SubstitutionRule(field: .body, match: "foo", replacement: "bar"),
            SubstitutionRule(field: .body, match: "", replacement: "ignored"), // empty → dropped
        ]
        let out = built(rule).actions.requestSubstitutions
        #expect(out.count == 1)
        #expect(out.first?.match == "foo")
    }

    // MARK: The whole model at once

    /// A rule with *every* field populated, opened in the editor and saved
    /// untouched, must come back byte-identical. The per-field tests above each
    /// prove one carried field; this proves nothing else was quietly lost along
    /// the way — the failure mode `RuleDraft`'s `carried*` fields exist for.
    @Test func maximalRule_roundTripsUnchanged() {
        let rule = TrafficRule(
            name: "maximal",
            comment: "why this rule exists",
            group: "scenario-a",
            isEnabled: false,
            match: RuleMatch(
                urlPattern: "https://api.example.com/v1/*",
                isRegex: false,
                methods: ["GET", "POST"],
                isExact: false,
                hostPattern: "*.example.com",
                query: ["ab_test": "on"],
                sourceApp: "com.example.MyApp",
                deviceIP: "192.168.1.9"
            ),
            actions: RuleActions(
                route: .mock(MockResponseAction(
                    statusCode: 418,
                    headers: [HeaderPair(name: "X-Mock", value: "yes")],
                    bodyText: #"{"ok":true}"#,
                    contentType: "application/json"
                )),
                rewriteRequest: RequestRewriteAction(
                    method: "PUT",
                    setHeaders: [HeaderPair(name: "X-Req", value: "1")],
                    removeHeaders: ["Cookie"],
                    bodyText: "req-body"
                ),
                rewriteResponse: ResponseRewriteAction(
                    statusCode: 503,
                    setHeaders: [HeaderPair(name: "X-Res", value: "2")],
                    removeHeaders: ["Set-Cookie"],
                    bodyText: "res-body"
                ),
                requestSubstitutions: [SubstitutionRule(field: .url, match: "a", replacement: "b", caseSensitive: true)],
                responseSubstitutions: [SubstitutionRule(field: .body, match: "c", replacement: "d", isRegex: true)],
                delayMilliseconds: 250
            )
        )
        #expect(built(rule) == rule)
    }

    /// Pins the *shape* of the model the editor mirrors.
    ///
    /// The fixture above is hand-written, so a newly added `TrafficRule` field would
    /// simply take its default there and the round-trip would still pass while the
    /// editor silently dropped the field on save. This census is reflection-based, so
    /// a new field breaks it immediately — and the fix is to decide, deliberately,
    /// whether `RuleDraft` surfaces it or carries it.
    @Test func modelShape_isPinnedSoNewFieldsAreNoticed() {
        let expected: Set<String> = [
            // TrafficRule
            "id", "name", "comment", "group", "isEnabled", "match", "actions", "createdAt",
            // RuleMatch
            "urlPattern", "isRegex", "methods", "isExact", "hostPattern", "query",
            "sourceApp", "deviceIP",
            // RuleActions
            "route", "rewriteRequest", "rewriteResponse",
            "requestSubstitutions", "responseSubstitutions", "delayMilliseconds",
            // Route payloads (mock shown here; the others are covered by the
            // per-route tests above, and adding a Route case is a compile error in
            // MCPServerTests' RuleCodecParityTests)
            "mock", "statusCode", "headers", "bodyText", "bodyBase64", "contentType",
            // Rewrites
            "method", "setHeaders", "removeHeaders",
            // SubstitutionRule
            "field", "replacement", "caseSensitive",
        ]
        let actual = Self.fieldNames(of: maximalRuleForCensus)
        let added = actual.subtracting(expected)
        let removed = expected.subtracting(actual)
        #expect(added.isEmpty, """
        New TrafficRule field(s) \(added.sorted()): decide whether RuleDraft surfaces \
        them in the editor or carries them through untouched (see the `carried*` \
        fields), add a round-trip assertion, then add them here. The MCP schema and \
        render need the same treatment — see RuleCodecParityTests.
        """)
        #expect(removed.isEmpty, "field(s) \(removed.sorted()) are gone from the model; drop them here too")
    }

    private var maximalRuleForCensus: TrafficRule {
        TrafficRule(
            name: "census",
            comment: "c",
            group: "g",
            match: RuleMatch(urlPattern: "x", hostPattern: "h", query: ["q": "1"], sourceApp: "a", deviceIP: "1.2.3.4"),
            actions: RuleActions(
                route: .mock(MockResponseAction(bodyText: "b", bodyBase64: "Yg==", contentType: "text/plain")),
                rewriteRequest: RequestRewriteAction(method: "GET", bodyText: "b"),
                rewriteResponse: ResponseRewriteAction(statusCode: 200, bodyText: "b"),
                requestSubstitutions: [SubstitutionRule(field: .url, match: "m", replacement: "r")],
                responseSubstitutions: [SubstitutionRule(field: .body, match: "m", replacement: "r")],
                delayMilliseconds: 1
            )
        )
    }

    /// Stored-property names of a value and everything it holds. `Mirror`, not the
    /// Codable encoding: an encoding omits a nil optional entirely, which would make
    /// the census bless a newly added optional field — the exact drift it guards.
    private static func fieldNames(of value: Any) -> Set<String> {
        if value is String || value is Int || value is Bool || value is Double
            || value is UUID || value is Date || value is Data { return [] }
        var names: Set<String> = []
        let mirror = Mirror(reflecting: value)
        switch mirror.displayStyle {
        case .dictionary:
            return [] // free-form data: keys are values, not fields
        case .optional:
            if let wrapped = mirror.children.first?.value { names.formUnion(fieldNames(of: wrapped)) }
        default:
            for child in mirror.children {
                guard let label = child.label, !label.isEmpty else {
                    names.formUnion(fieldNames(of: child.value)) // collection element
                    continue
                }
                names.insert(label)
                names.formUnion(fieldNames(of: child.value))
            }
        }
        return names
    }

    // MARK: New match fields (isExact / hostPattern / query) round-trip

    @Test func matchFields_roundTrip() {
        let rule = TrafficRule(
            name: "exact + host + query",
            match: RuleMatch(
                urlPattern: "https://api.example.com/v1/home",
                isExact: true,
                hostPattern: "*.example.com",
                query: ["ab_test": "on", "debug": "*"]
            ),
            actions: RuleActions(route: .block)
        )
        let out = built(rule).match
        #expect(out.isExact)
        #expect(out.hostPattern == "*.example.com")
        #expect(out.query == ["ab_test": "on", "debug": "*"])
    }

    /// A rule an agent scoped to one app or device must survive a human opening it in
    /// the editor and pressing Save — silently widening "mock this for my app" to
    /// "mock this for everything" is the worst kind of drop, because the rule still
    /// looks right.
    @Test func originScope_roundTrips() {
        let rule = TrafficRule(
            name: "app-scoped mock",
            match: RuleMatch(
                urlPattern: "https://api.example.com/v1/*",
                sourceApp: "com.example.MyApp",
                deviceIP: "192.168.1.9"
            ),
            actions: RuleActions(route: .block)
        )
        let out = built(rule).match
        #expect(out.sourceApp == "com.example.MyApp")
        #expect(out.deviceIP == "192.168.1.9")
    }

    @Test func blankOriginFields_meanAnyClient() {
        var draft = RuleDraft(rule: TrafficRule(
            name: "r",
            match: RuleMatch(urlPattern: "https://api.example.com/x", sourceApp: "com.example.MyApp"),
            actions: RuleActions(route: .block)
        ))
        draft.sourceApp = "   " // cleared by the human
        guard case let .success(rule) = draft.build() else {
            Issue.record("build failed")
            return
        }
        #expect(rule.match.sourceApp == nil, "whitespace is not a scope")
        #expect(!rule.match.constrainsOrigin)
    }

    @Test func enablingRegex_clearsExact() throws {
        var draft = RuleDraft(rule: TrafficRule(
            name: "r",
            match: RuleMatch(urlPattern: "https://api.example.com/home", isExact: true),
            actions: RuleActions(route: .block)
        ))
        draft.isRegex = true // user flips regex on; exact must not survive into the model
        guard case let .success(rule) = draft.build() else {
            Issue.record("build failed")
            return
        }
        #expect(rule.match.isRegex)
        #expect(!rule.match.isExact)
    }

    @Test func blankQueryRows_droppedOnBuild() {
        var draft = RuleDraft(rule: Fixtures.rule(route: .block))
        draft.queryItems = [QueryItem(key: "keep", value: "1"), QueryItem(key: "  ", value: "ignored")]
        guard case let .success(rule) = draft.build() else {
            Issue.record("build failed")
            return
        }
        #expect(rule.match.query == ["keep": "1"])
    }

    // MARK: Binary (base64) mock body

    @Test func mockBodyBase64_roundTrips() {
        let mock = MockResponseAction(statusCode: 200, bodyBase64: "aGVsbG8=", contentType: "application/octet-stream")
        let rule = Fixtures.rule(route: .mock(mock))
        guard case let .mock(out) = built(rule).actions.route else {
            Issue.record("expected mock route")
            return
        }
        #expect(out.bodyBase64 == "aGVsbG8=")
        #expect(out.bodyText == nil, "a binary body must not also carry text")
    }

    @Test func mockBody_invalidBase64_fails() {
        var draft = RuleDraft(rule: Fixtures.rule(route: .mock(MockResponseAction())))
        draft.mockBodyIsBinary = true
        draft.mockBodyBase64 = "not valid base64!!!"
        guard case .failure = draft.build() else {
            Issue.record("expected a build failure for invalid base64")
            return
        }
    }

    // MARK: Validation failures surface as a message, not a crash

    @Test func build_nonNumericMockStatus_fails() {
        var draft = RuleDraft(rule: Fixtures.rule(route: .mock(MockResponseAction())))
        draft.mockStatus = "abc"
        guard case .failure = draft.build() else {
            Issue.record("expected a build failure for a non-numeric status")
            return
        }
    }

    @Test func build_nonNumericDelay_fails() {
        var draft = RuleDraft(rule: Fixtures.rule(route: .block))
        draft.delayOn = true
        draft.delayMs = "soon"
        guard case .failure = draft.build() else {
            Issue.record("expected a build failure for a non-numeric delay")
            return
        }
    }

    @Test func build_emptyName_fails() {
        var draft = RuleDraft(rule: Fixtures.rule(route: .block))
        draft.name = "   "
        guard case .failure = draft.build() else {
            Issue.record("expected a build failure for an empty name")
            return
        }
    }
}
