import Foundation
import LoomSharedModels
import Testing

@testable import AppFeature

/// `RuleDraft` is the flattened, editable mirror of a `TrafficRule`. Its contract
/// is that every field of the model is reachable from the editor and survives a
/// round trip — the fields that used to be merely *carried* (mapLocal,
/// rewriteResponse, mock headers, multi-method matches, comments) are now edited
/// like the rest, so these tests check both that they round-trip and that editing
/// them lands in the model.
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

    @Test func mock_preservesStatusBodyAndHeaders() {
        let mock = MockResponseAction(
            statusCode: 201,
            headers: [HeaderPair(name: "X-Debug", value: "1")],
            body: .text(#"{"ok":true}"#),
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

    @Test func mapLocal_roundTrips() {
        let local = MapLocalAction(path: "/tmp/fixture.json", statusCode: 200, contentType: "application/json")
        let rule = Fixtures.rule(route: .mapLocal(local))
        #expect(built(rule).actions.route == .mapLocal(local))
    }

    /// The failure this whole redesign is about: a `mapLocal` route used to be an
    /// invisible carried field that `build()` only restored when nothing else had
    /// claimed the route — so turning on Mock (or Redirect) destroyed it with no
    /// indication. It is a picker case now, so the two are the *same* property and
    /// switching away and back keeps the payload.
    @Test func mapLocal_survivesSwitchingRouteAwayAndBack() {
        let local = MapLocalAction(path: "/tmp/fixture.json", statusCode: 204, contentType: "application/json")
        var draft = RuleDraft(rule: Fixtures.rule(route: .mapLocal(local)))
        #expect(draft.responseSource == .shortCircuit)
        #expect(draft.respBodySource == .file)

        draft.setResponseBodySource(.text)
        guard case let .success(mocked) = draft.build() else {
            Issue.record("build failed")
            return
        }
        guard case .mock = mocked.actions.route else {
            Issue.record("expected a mock route")
            return
        }

        draft.setResponseBodySource(.file)
        guard case let .success(back) = draft.build() else {
            Issue.record("build failed")
            return
        }
        #expect(back.actions.route == .mapLocal(local), "the local-file payload must not be lost by a detour")
    }

    @Test func mapLocal_editedPathLandsInTheModel() {
        var draft = RuleDraft(rule: Fixtures.rule(route: .block))
        draft.setResponseBodySource(.file)
        draft.respBodyFile = "/tmp/edited.json"
        draft.respStatus = "201"
        draft.respContentType = "text/plain"
        guard case let .success(rule) = draft.build() else {
            Issue.record("build failed")
            return
        }
        #expect(rule.actions.route == .mapLocal(
            MapLocalAction(path: "/tmp/edited.json", statusCode: 201, contentType: "text/plain")))
    }

    @Test func mapLocal_relativePath_fails() {
        var draft = RuleDraft(rule: Fixtures.rule(route: .block))
        draft.setResponseBodySource(.file)
        draft.respBodyFile = "fixtures/home.json"
        guard case .failure = draft.build() else {
            Issue.record("expected a build failure for a non-absolute path")
            return
        }
    }

    @Test func mapLocal_nonNumericStatus_fails() {
        var draft = RuleDraft(rule: Fixtures.rule(route: .block))
        draft.setResponseBodySource(.file)
        draft.respBodyFile = "/tmp/x.json"
        draft.respStatus = "two hundred"
        guard case .failure = draft.build() else {
            Issue.record("expected a build failure for a non-numeric status")
            return
        }
    }

    // MARK: The route is one property, so two segments can't both claim it

    @Test func choosingMock_turnsRedirectOff() {
        var draft = RuleDraft(rule: Fixtures.rule(
            route: .mapRemote(MapRemoteAction(destination: "http://127.0.0.1:3001"))))
        #expect(draft.redirectOn)
        #expect(draft.responseSource == .upstream, "a redirect is an upstream source")

        draft.responseSource = .shortCircuit
        #expect(!draft.redirectOn, "the redirect must visibly turn off, not be dropped at save time")
        guard case let .success(rule) = draft.build() else {
            Issue.record("build failed")
            return
        }
        guard case .mock = rule.actions.route else {
            Issue.record("expected a mock route")
            return
        }
    }

    @Test func settingResponsePickerOff_doesNotKillARedirect() {
        var draft = RuleDraft(rule: Fixtures.rule(
            route: .mapRemote(MapRemoteAction(destination: "http://127.0.0.1:3001"))))
        draft.responseSource = .upstream // already reads upstream; re-picking must be a no-op
        #expect(draft.redirectOn)
        #expect(draft.route == .mapRemote)
    }

    @Test func turningRedirectOn_clearsAMockRoute() {
        var draft = RuleDraft(rule: Fixtures.rule(route: .mock(MockResponseAction())))
        #expect(draft.routeClaimedElsewhere)
        draft.redirectOn = true
        draft.redirectDest = "http://127.0.0.1:3001"
        #expect(draft.responseSource == .upstream)
        guard case let .success(rule) = draft.build() else {
            Issue.record("build failed")
            return
        }
        #expect(rule.actions.route == .mapRemote(MapRemoteAction(destination: "http://127.0.0.1:3001")))
    }

    @Test func mapRemote_roundTrips() {
        let remote = MapRemoteAction(destination: "http://127.0.0.1:3001", keepHostHeader: true)
        let rule = Fixtures.rule(route: .mapRemote(remote))
        #expect(built(rule).actions.route == .mapRemote(remote))
    }

    @Test func rewriteResponse_roundTrips() {
        var rule = Fixtures.rule(route: .passthrough)
        let rewrite = ResponseRewriteAction(statusCode: 418, bodyText: "teapot")
        rule.actions.rewriteResponse = rewrite
        #expect(built(rule).actions.rewriteResponse == rewrite)
    }

    /// With the source short-circuiting, the three sections *are* the synthesized
    /// response — status, headers and body land on the mock itself rather than as
    /// a rewrite that says the same thing a second time.
    @Test func shortCircuitSections_landOnTheMockItself() {
        var draft = RuleDraft(rule: Fixtures.rule(route: .mock(MockResponseAction(statusCode: 200))))
        #expect(draft.responseSource == .shortCircuit)
        draft.respStatus = "503"
        draft.respSetHeaders = "X-Res: 2"
        draft.respBodyOn = true
        draft.respBodySource = .text
        draft.respBody = "res-body"
        guard case let .success(rule) = draft.build(), case let .mock(mock) = rule.actions.route else {
            Issue.record("expected a mock route")
            return
        }
        #expect(mock.statusCode == 503)
        #expect(mock.headers == [HeaderPair(name: "X-Res", value: "2")])
        #expect(mock.body == .text("res-body"))
        #expect(rule.actions.rewriteResponse == nil, "no second copy of the same instruction")
    }

    /// The one combination the pane has no room to lay out: a synthesized route
    /// **plus** a response rewrite (which an agent can write, and which behaves
    /// differently from folding it into the mock when several rules match). It is
    /// carried through untouched — and, unlike the old carried fields, the draft
    /// can say it is there so the editor can name it.
    @Test func aRewriteOverAMock_isCarried_andAnnounced() {
        var rule = Fixtures.rule(route: .mock(MockResponseAction(statusCode: 200)))
        let rewrite = ResponseRewriteAction(statusCode: 503, setHeaders: [HeaderPair(name: "X-Res", value: "2")])
        rule.actions.rewriteResponse = rewrite

        let draft = RuleDraft(rule: rule)
        #expect(draft.carriedResponseRewriteSummary == "status + headers")
        #expect(built(rule).actions.rewriteResponse == rewrite)
        #expect(built(rule) == rule, "opening and saving must change nothing")
    }

    /// On the upstream path there is nothing to carry — the sections are the
    /// rewrite — so the notice must not appear.
    @Test func noCarriedRewriteNotice_onTheUpstreamPath() {
        var rule = Fixtures.rule(route: .passthrough)
        rule.actions.rewriteResponse = ResponseRewriteAction(statusCode: 503)
        #expect(RuleDraft(rule: rule).carriedResponseRewriteSummary == nil)
    }

    @Test func rewriteResponse_blankStatusMeansKeepIt() {
        var draft = RuleDraft(rule: Fixtures.rule(route: .passthrough))
        draft.respStatus = "  "
        draft.respBodyOn = true
        draft.respBodySource = .text
        draft.respBody = "only the body"
        guard case let .success(rule) = draft.build() else {
            Issue.record("build failed")
            return
        }
        #expect(rule.actions.rewriteResponse?.statusCode == nil)
        #expect(rule.actions.rewriteResponse?.bodyText == "only the body")
    }

    @Test func rewriteResponse_nonNumericStatus_fails() {
        var draft = RuleDraft(rule: Fixtures.rule(route: .block))
        draft.respStatus = "teapot"
        guard case .failure = draft.build() else {
            Issue.record("expected a build failure for a non-numeric status override")
            return
        }
    }

    /// Clearing the field is how a rewrite is removed — there is no switch to turn
    /// off, so an empty status has to mean "no status override" rather than
    /// leaving the old one stranded in the model. The rule keeps another action so
    /// it stays valid; a rule with nothing left is refused, which is a different
    /// rule.
    @Test func rewriteResponse_clearedField_isRemovedNotStranded() {
        var rule = Fixtures.rule(route: .passthrough)
        rule.actions.rewriteResponse = ResponseRewriteAction(statusCode: 418)
        rule.actions.delayMilliseconds = 100
        var draft = RuleDraft(rule: rule)
        #expect(draft.responseLineEdited)
        draft.respStatus = ""
        guard case let .success(out) = draft.build() else {
            Issue.record("build failed")
            return
        }
        #expect(out.actions.rewriteResponse == nil, "the human must be able to delete it, not just see it")
        #expect(out.actions.delayMilliseconds == 100)
    }

    /// Block hides the three response sections — a 403 with a fixed body has
    /// nothing to edit — so a rewrite on a blocking rule is carried, not dropped.
    /// It was dropped, and this is the test that found it.
    @Test func aRewriteOnABlockingRule_survivesASave() {
        var rule = Fixtures.rule(route: .block)
        let rewrite = ResponseRewriteAction(statusCode: 451, bodyText: "gone")
        rule.actions.rewriteResponse = rewrite
        #expect(built(rule).actions.rewriteResponse == rewrite)
        #expect(built(rule) == rule)
        #expect(RuleDraft(rule: rule).carriedResponseRewriteSummary == "status + body")
    }

    @Test func mockHeaders_areEditable() {
        var draft = RuleDraft(rule: Fixtures.rule(route: .mock(
            MockResponseAction(headers: [HeaderPair(name: "X-Debug", value: "1")]))))
        draft.respSetHeaders = "X-Debug: 2\nX-New: yes"
        guard case let .success(rule) = draft.build(), case let .mock(mock) = rule.actions.route else {
            Issue.record("expected a mock route")
            return
        }
        #expect(mock.headers == [HeaderPair(name: "X-Debug", value: "2"), HeaderPair(name: "X-New", value: "yes")])
    }

    @Test func comment_isEditable() {
        var rule = Fixtures.rule(route: .block)
        rule.comment = "authored via MCP"
        #expect(built(rule).comment == "authored via MCP")

        var draft = RuleDraft(rule: rule)
        draft.comment = "  " // cleared by the human
        guard case let .success(out) = draft.build() else {
            Issue.record("build failed")
            return
        }
        #expect(out.comment == nil, "whitespace is not a note")
    }

    @Test func emptyGroup_buildsAsUngrouped() {
        let grouped = Fixtures.rule(group: "scenario-a", route: .block)
        var draft = RuleDraft(rule: grouped)
        #expect(draft.group == "scenario-a")
        draft.group = ""
        guard case let .success(cleared) = draft.build() else {
            Issue.record("build failed")
            return
        }
        #expect(cleared.group == nil)

        draft.group = "  "
        guard case let .success(whitespace) = draft.build() else {
            Issue.record("build failed")
            return
        }
        #expect(whitespace.group == nil, "whitespace is not a group")
    }

    @Test func newRule_opensWithNoGroup() {
        let blank = TrafficRule(name: "", match: RuleMatch(urlPattern: ""), actions: RuleActions())
        let draft = RuleDraft(rule: blank)
        #expect(draft.group.isEmpty)
        // Can't build — name and pattern are empty — but the field itself must
        // not pick up a neighbouring group's name.
    }

    @Test func multiMethod_roundTrips() {
        let rule = Fixtures.rule(methods: ["GET", "HEAD"], route: .block)
        #expect(built(rule).match.methods == ["GET", "HEAD"])
    }

    /// The old single-select dropdown showed the first method and replaced the
    /// whole set on save, so editing a `["POST","PUT"]` rule to also cover GET
    /// silently dropped PUT. Multi-select edits the list itself.
    @Test func multiMethod_editingOneKeepsTheOthers() {
        var draft = RuleDraft(rule: Fixtures.rule(methods: ["POST", "PUT"], route: .block))
        draft.methods.append("GET")
        guard case let .success(rule) = draft.build() else {
            Issue.record("build failed")
            return
        }
        #expect(rule.match.methods == ["POST", "PUT", "GET"])

        draft.methods.removeAll { $0 == "POST" }
        guard case let .success(narrowed) = draft.build() else {
            Issue.record("build failed")
            return
        }
        #expect(narrowed.match.methods == ["PUT", "GET"])
    }

    @Test func noMethods_meansAnyMethod() {
        var draft = RuleDraft(rule: Fixtures.rule(methods: ["GET"], route: .block))
        draft.methods = []
        guard case let .success(rule) = draft.build() else {
            Issue.record("build failed")
            return
        }
        #expect(rule.match.methods.isEmpty)
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
                style: .glob,
                methods: ["GET", "POST"],
                query: ["ab_test": .equals("on")],
                sourceApp: "com.example.MyApp",
                deviceIP: "192.168.1.9"
            ),
            actions: RuleActions(
                route: .mock(MockResponseAction(
                    statusCode: 418,
                    headers: [HeaderPair(name: "X-Mock", value: "yes")],
                    body: .text(#"{"ok":true}"#),
                    contentType: "application/json"
                )),
                rewriteRequest: RequestRewriteAction(
                    method: "PUT",
                    url: "https://api.example.com/v2/home",
                    setHeaders: [HeaderPair(name: "X-Req", value: "1")],
                    removeHeaders: ["Cookie"],
                    body: .text("req-body")
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
            // RuleMatch ("isRegex" below belongs to SubstitutionRule; RuleMatch's
            // own regex/exact booleans are one `style` enum now)
            "urlPattern", "style", "methods", "query",
            "sourceApp", "deviceIP", "expiredHostPattern",
            // RuleActions
            "route", "rewriteRequest", "rewriteResponse",
            "requestSubstitutions", "responseSubstitutions", "delayMilliseconds",
            // The capture stage: the one action that does not touch the traffic. The
            // editor surfaces it in Advanced (`RuleDraft.dropFromCapture`).
            "dropFromCapture",
            // Route payloads (mock shown here; the others are covered by the
            // per-route tests above, and adding a Route case is a compile error in
            // MCPServerTests' RuleCodecParityTests)
            "mock", "statusCode", "headers", "contentType",
            // MockBody: the census fixture below uses `.bytes`, so `text` is not
            // in this set — `MockBodyTests` covers the other case.
            "body", "bytes",
            // Rewrites. The request's body is a `RewriteBody` (`text`/`file`);
            // `bodyText` is the response rewrite's, which stays a plain string
            // because a file body there is `mapLocal`, not a rewrite.
            "method", "url", "setHeaders", "removeHeaders", "bodyText", "text",
            // SubstitutionRule ("isRegex" is this type's, not the match's)
            "field", "replacement", "caseSensitive", "isRegex",
            // RuleMatch's prepared glob: a cache derived from urlPattern + style, not
            // a field anyone authors, encodes or reads back (RulePreparedPatternTests
            // pins that it cannot go stale).
            "preparedGlob",
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
            match: RuleMatch(urlPattern: "x", query: ["q": .equals("1")], sourceApp: "a", deviceIP: "1.2.3.4"),
            actions: RuleActions(
                route: .mock(MockResponseAction(body: .bytes(Data("b".utf8)), contentType: "text/plain")),
                rewriteRequest: RequestRewriteAction(method: "GET", body: .text("b")),
                rewriteResponse: ResponseRewriteAction(statusCode: 200, bodyText: "b"),
                requestSubstitutions: [SubstitutionRule(field: .url, match: "m", replacement: "r")],
                responseSubstitutions: [SubstitutionRule(field: .body, match: "m", replacement: "r")],
                delayMilliseconds: 1,
                dropFromCapture: true
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

    // MARK: Match fields (exact / query) round-trip

    @Test func matchFields_roundTrip() {
        let rule = TrafficRule(
            name: "exact + query",
            match: RuleMatch(
                urlPattern: "https://api.example.com/v1/home",
                style: .exact,
                query: ["ab_test": .equals("on"), "debug": .present]
            ),
            actions: RuleActions(route: .block)
        )
        let out = built(rule).match
        #expect(out.isExact)
        #expect(out.query == ["ab_test": .equals("on"), "debug": .present])
    }

    /// A leftover host glob is a warning, and **Save refuses until it is
    /// resolved**. The old shape is `urlPattern: "*"` plus the glob, so silently
    /// dropping it turns "block this one origin" into "block everything" on a
    /// keystroke the human read as acknowledging a warning.
    @Test func expiredHostPattern_blocksSaveUntilResolved() {
        let rule = expiredRule()
        let draft = RuleDraft(rule: rule)
        #expect(draft.expiredHostPattern == "*.example.com")
        guard case let .failure(error) = draft.build() else {
            Issue.record("an expired rule must not save as-is")
            return
        }
        #expect(error.message.contains("*.example.com"))
        #expect(error.message.contains("https://*.example.com*"), "the message carries the folded pattern")
    }

    @Test func foldHostIntoURL_keepsTheHostScope() {
        var draft = RuleDraft(rule: expiredRule())
        #expect(draft.foldedURLSuggestion == "https://*.example.com*")
        draft.foldHostIntoURL()
        #expect(draft.expiredHostPattern == nil)
        guard case let .success(out) = draft.build() else {
            Issue.record("build failed after folding")
            return
        }
        #expect(out.match.urlPattern == "https://*.example.com*")
        #expect(out.match.style == .glob)
        #expect(out.match.isExpired == false)
        #expect(out.match.matches(method: "GET", url: "https://api.example.com/x"))
        #expect(!out.match.matches(method: "GET", url: "https://api.other.com/x"))
    }

    /// The other exit exists, and it is a named choice rather than what Save does
    /// by default.
    @Test func widenToEveryHost_isDeliberateAndSaves() {
        var draft = RuleDraft(rule: expiredRule())
        draft.widenToEveryHost()
        guard case let .success(out) = draft.build() else {
            Issue.record("build failed after widening")
            return
        }
        #expect(out.match.isExpired == false)
        #expect(out.match.urlPattern == "*")
        #expect(out.match.matches(method: "GET", url: "https://api.other.com/x"))
    }

    /// A path-anchored pattern folds too; a regex or an exact URL gets no
    /// suggestion, because no string edit reproduces "this regex AND that host".
    @Test func foldedSuggestion_onlyForShapesItCanRewriteFaithfully() {
        #expect(RuleDraft.foldedURLPattern(host: "api.test", into: "") == "https://api.test*")
        #expect(RuleDraft.foldedURLPattern(host: "api.test", into: "*") == "https://api.test*")
        #expect(RuleDraft.foldedURLPattern(host: "api.test", into: "*/orders*") == "https://api.test/orders*")
        // A pattern anchored at `/` never matched a whole URL, so folding a host
        // into it would turn a dead rule live rather than preserve a scope.
        #expect(RuleDraft.foldedURLPattern(host: "api.test", into: "/orders*") == nil)
        #expect(RuleDraft.foldedURLPattern(host: "api.test", into: "https://other.test/x") == nil)
        #expect(RuleDraft.foldedURLPattern(host: "", into: "*") == nil)

        var regexDraft = RuleDraft(rule: TrafficRule(
            name: "regex + host",
            match: RuleMatch(urlPattern: ".*/orders", style: .regex, expiredHostPattern: "*.example.com"),
            actions: RuleActions(route: .block)
        ))
        #expect(regexDraft.foldedURLSuggestion == nil)
        regexDraft.foldHostIntoURL()
        #expect(regexDraft.expiredHostPattern == "*.example.com", "nothing to fold means nothing changes")
        if case .success = regexDraft.build() { Issue.record("an unresolved leftover must not save") }
    }

    private func expiredRule() -> TrafficRule {
        TrafficRule(
            name: "old host glob",
            match: RuleMatch(urlPattern: "*", expiredHostPattern: "*.example.com"),
            actions: RuleActions(route: .block)
        )
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
            match: RuleMatch(urlPattern: "https://api.example.com/home", style: .exact),
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
        #expect(rule.match.query == ["keep": .equals("1")])
    }

    // MARK: Binary (base64) mock body

    @Test func mockBodyBase64_roundTrips() {
        let mock = MockResponseAction(statusCode: 200, body: .bytes(Data("hello".utf8)), contentType: "application/octet-stream")
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
        draft.respBodyOn = true
        draft.respBodySource = .binary
        draft.respBodyBase64 = "not valid base64!!!"
        guard case .failure = draft.build() else {
            Issue.record("expected a build failure for invalid base64")
            return
        }
    }

    // MARK: Validation failures surface as a message, not a crash

    @Test func build_nonNumericMockStatus_fails() {
        var draft = RuleDraft(rule: Fixtures.rule(route: .mock(MockResponseAction())))
        draft.respStatus = "abc"
        guard case .failure = draft.build() else {
            Issue.record("expected a build failure for a non-numeric status")
            return
        }
    }

    @Test func build_nonNumericDelay_fails() {
        var draft = RuleDraft(rule: Fixtures.rule(route: .block))
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
