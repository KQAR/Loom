import SharedModels
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
