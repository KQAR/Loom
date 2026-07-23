import SharedModels
import XCTest

@testable import AppFeature

/// `RuleDraft` is the flattened, editable mirror of a `TrafficRule`. Its contract
/// is that editing a rule the UI doesn't fully surface (mapLocal, rewriteResponse,
/// multi-method matches, comments) never silently drops those fields on save.
final class RuleDraftTests: XCTestCase {
    private func built(_ rule: TrafficRule) -> TrafficRule {
        switch RuleDraft(rule: rule).build() {
        case let .success(r): return r
        case let .failure(e): XCTFail("build failed: \(e.message)"); return rule
        }
    }

    func test_block_roundTripsExactly() {
        let rule = Fixtures.rule(name: "Block home", route: .block)
        XCTAssertEqual(built(rule), rule)
    }

    func test_mock_preservesStatusBodyAndCarriedHeaders() {
        let mock = MockResponseAction(
            statusCode: 201,
            headers: [HeaderPair(name: "X-Debug", value: "1")], // MCP-set, editor doesn't surface
            bodyText: #"{"ok":true}"#,
            contentType: "application/json"
        )
        let rule = Fixtures.rule(route: .mock(mock))
        guard case let .mock(out) = built(rule).actions.route else {
            return XCTFail("expected a mock route")
        }
        XCTAssertEqual(out.statusCode, 201)
        XCTAssertEqual(out.bodyText, #"{"ok":true}"#)
        XCTAssertEqual(out.contentType, "application/json")
        XCTAssertEqual(out.headers, [HeaderPair(name: "X-Debug", value: "1")])
    }

    func test_mapLocal_carriedThroughUnsurfacedByEditor() {
        let local = MapLocalAction(path: "/tmp/fixture.json", statusCode: 200, contentType: "application/json")
        let rule = Fixtures.rule(route: .mapLocal(local))
        XCTAssertEqual(built(rule).actions.route, .mapLocal(local))
    }

    func test_mapRemote_roundTrips() {
        let remote = MapRemoteAction(destination: "http://127.0.0.1:3001", keepHostHeader: true)
        let rule = Fixtures.rule(route: .mapRemote(remote))
        XCTAssertEqual(built(rule).actions.route, .mapRemote(remote))
    }

    func test_rewriteResponse_carriedThrough() {
        var rule = Fixtures.rule(route: .passthrough)
        let rewrite = ResponseRewriteAction(statusCode: 418, bodyText: "teapot")
        rule.actions.rewriteResponse = rewrite
        XCTAssertEqual(built(rule).actions.rewriteResponse, rewrite)
    }

    func test_comment_preservedThoughEditorHidesIt() {
        var rule = Fixtures.rule(route: .block)
        rule.comment = "authored via MCP"
        XCTAssertEqual(built(rule).comment, "authored via MCP")
    }

    func test_multiMethod_matchPreservedWhenUntouched() {
        let rule = Fixtures.rule(methods: ["GET", "HEAD"], route: .block)
        // Editor's single-select dropdown shows the first method but must keep the set.
        XCTAssertEqual(built(rule).match.methods, ["GET", "HEAD"])
    }

    func test_delay_roundTrips() {
        var rule = Fixtures.rule(route: .passthrough)
        rule.actions.delayMilliseconds = 250
        XCTAssertEqual(built(rule).actions.delayMilliseconds, 250)
    }

    func test_substitutions_dropEmptyRowsOnBuild() {
        var rule = Fixtures.rule(route: .passthrough)
        rule.actions.requestSubstitutions = [
            SubstitutionRule(field: .body, match: "foo", replacement: "bar"),
            SubstitutionRule(field: .body, match: "", replacement: "ignored"), // empty → dropped
        ]
        let out = built(rule).actions.requestSubstitutions
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out.first?.match, "foo")
    }

    // MARK: New match fields (isExact / hostPattern / query) round-trip

    func test_matchFields_roundTrip() {
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
        XCTAssertTrue(out.isExact)
        XCTAssertEqual(out.hostPattern, "*.example.com")
        XCTAssertEqual(out.query, ["ab_test": "on", "debug": "*"])
    }

    func test_enablingRegex_clearsExact() {
        var draft = RuleDraft(rule: TrafficRule(
            name: "r",
            match: RuleMatch(urlPattern: "https://api.example.com/home", isExact: true),
            actions: RuleActions(route: .block)
        ))
        draft.isRegex = true // user flips regex on; exact must not survive into the model
        guard case let .success(rule) = draft.build() else { return XCTFail("build failed") }
        XCTAssertTrue(rule.match.isRegex)
        XCTAssertFalse(rule.match.isExact)
    }

    func test_blankQueryRows_droppedOnBuild() {
        var draft = RuleDraft(rule: Fixtures.rule(route: .block))
        draft.queryItems = [QueryItem(key: "keep", value: "1"), QueryItem(key: "  ", value: "ignored")]
        guard case let .success(rule) = draft.build() else { return XCTFail("build failed") }
        XCTAssertEqual(rule.match.query, ["keep": "1"])
    }

    // MARK: Binary (base64) mock body

    func test_mockBodyBase64_roundTrips() {
        let mock = MockResponseAction(statusCode: 200, bodyBase64: "aGVsbG8=", contentType: "application/octet-stream")
        let rule = Fixtures.rule(route: .mock(mock))
        guard case let .mock(out) = built(rule).actions.route else { return XCTFail("expected mock route") }
        XCTAssertEqual(out.bodyBase64, "aGVsbG8=")
        XCTAssertNil(out.bodyText, "a binary body must not also carry text")
    }

    func test_mockBody_invalidBase64_fails() {
        var draft = RuleDraft(rule: Fixtures.rule(route: .mock(MockResponseAction())))
        draft.mockBodyIsBinary = true
        draft.mockBodyBase64 = "not valid base64!!!"
        guard case .failure = draft.build() else {
            return XCTFail("expected a build failure for invalid base64")
        }
    }

    // MARK: Validation failures surface as a message, not a crash

    func test_build_nonNumericMockStatus_fails() {
        var draft = RuleDraft(rule: Fixtures.rule(route: .mock(MockResponseAction())))
        draft.mockStatus = "abc"
        guard case .failure = draft.build() else {
            return XCTFail("expected a build failure for a non-numeric status")
        }
    }

    func test_build_nonNumericDelay_fails() {
        var draft = RuleDraft(rule: Fixtures.rule(route: .block))
        draft.delayOn = true
        draft.delayMs = "soon"
        guard case .failure = draft.build() else {
            return XCTFail("expected a build failure for a non-numeric delay")
        }
    }

    func test_build_emptyName_fails() {
        var draft = RuleDraft(rule: Fixtures.rule(route: .block))
        draft.name = "   "
        guard case .failure = draft.build() else {
            return XCTFail("expected a build failure for an empty name")
        }
    }
}
