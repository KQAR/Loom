import Foundation
import LoomSharedModels
import Testing
@testable import MCPServer

/// Keeps the MCP rule codec from drifting away from `TrafficRule`.
///
/// A rule exists in four representations: the model (`TrafficRule`, Codable), the
/// `set_rule` **input schema** (snake_case, hand-written), the `list_rules`
/// **render** (camelCase, hand-written), and the editor's flattened `RuleDraft`.
/// Only the first is compiler-checked. Adding a field to the model therefore
/// compiles everywhere while the agent silently loses the ability to set or see
/// it — and `RuleDraft`'s five `carried*` fields are the scar tissue proving that
/// already happened once.
///
/// The guard here is a census: `TrafficRule`'s own Codable encoding is the
/// authoritative field list (the compiler grows it for free), and every field
/// must appear in the input schema and in the render, or be listed below as a
/// deliberate omission with a reason. Plus a full round-trip — maximal input →
/// stored rule → render — so "advertised" also means "actually parsed".
@MainActor
@Suite struct RuleCodecParityTests {
    private func makeExecutor(_ engine: StubEngine) -> MCPToolExecutor {
        MCPToolExecutor(engine: engine, appVersion: "9.9", protocolVersion: "2025-06-18")
    }

    // MARK: - The maximal rule: every field carries a distinguishable value

    /// One `actions` input per `Route` case. The `switch` is what makes a new route
    /// a compile error here: a route the codec can't express is a hole in the
    /// agent's vocabulary, and this is where that gets noticed.
    private func actionsInput(for route: Route) -> sending [String: Any] {
        var actions: [String: Any] = [
            "rewrite_request": [
                "method": "PUT",
                "url": "https://api.example.com/v2/home",
                "set_headers": ["X-Req": "1"],
                "remove_headers": ["Cookie"],
                "body": "req-body",
            ],
            "rewrite_response": [
                "status_code": 503,
                "set_headers": ["X-Res": "2"],
                "remove_headers": ["Set-Cookie"],
                "body": "res-body",
            ],
            "request_substitutions": [[
                "field": "url", "match": "a", "replacement": "b",
                "is_regex": false, "case_sensitive": true,
            ]],
            "response_substitutions": [[
                "field": "body", "match": "c", "replacement": "d",
                "is_regex": true, "case_sensitive": false,
            ]],
            "delay_ms": 250,
            "drop_from_capture": true,
        ]
        switch route {
        case .passthrough:
            break // no route key at all — the modifiers above carry the rule
        case .block:
            actions["block"] = true
        case .mock:
            actions["mock_response"] = [
                "status_code": 418,
                "headers": ["X-Mock": "yes"],
                "body": "mocked",
                "content_type": "application/json",
            ]
        case .mapLocal:
            actions["map_local"] = [
                "path": "/tmp/loom-fixture.json",
                "status_code": 201,
                "content_type": "application/json",
            ]
        case .mapRemote:
            actions["map_remote"] = [
                "destination": "http://127.0.0.1:3001",
                "exclude": "*/health",
                "keep_host_header": true,
            ]
        }
        return actions
    }

    /// Every route case, so the census below sees the union of all route fields.
    private var allRoutes: [Route] {
        [
            .passthrough,
            .block,
            .mock(MockResponseAction()),
            .mapLocal(MapLocalAction(path: "/tmp/x")),
            .mapRemote(MapRemoteAction(destination: "http://127.0.0.1:1")),
        ]
    }

    /// `sending` for the same reason as `BodyWarningTests.setRule`: this suite is
    /// `@MainActor` and `MCPToolExecutor.call` is nonisolated, so a plain return value
    /// would belong to the main-actor region. The dictionary is built fresh here and
    /// never kept, so it genuinely is disconnected.
    private func maximalInput(for route: Route) -> sending [String: Any] {
        // One variant is an exact match written the old way (`is_exact`), the rest
        // are regexes written the new way (`match_style`) — so the union covers
        // both spellings of the same field.
        let exactVariant = Self.routeCaseName(route) == "block"
        var match: [String: Any] = [
            "url_pattern": exactVariant
                ? "https://api.example.com/v1/home"
                : "https://api\\.example\\.com/.*",
            "host_pattern": "*.example.com",
            "query": ["v": "2"],
            "source_app": "com.example.app",
            "device_ip": "192.168.1.42",
            "methods": ["GET", "POST"],
        ]
        if exactVariant { match["is_exact"] = true } else { match["match_style"] = "regex" }
        return [
            "name": "maximal",
            "comment": "why this rule exists",
            "group": "scenario-a",
            "enabled": false,
            "match": match,
            "actions": actionsInput(for: route),
        ]
    }

    /// Create a rule through the real tool path and hand back what the engine stored.
    private func storedRule(for route: Route) async throws -> (TrafficRule, MCPToolExecutor, StubEngine) {
        let engine = StubEngine()
        let executor = makeExecutor(engine)
        _ = try await executor.call(name: "set_rule", arguments: maximalInput(for: route))
        let rule = try #require(engine.rules.rules.last)
        return (rule, executor, engine)
    }

    // MARK: - Round-trip: everything advertised is actually parsed

    @Test func maximalInput_parsesEveryFieldOfTheModel() async throws {
        let (rule, _, _) = try await storedRule(for: .mock(MockResponseAction()))

        #expect(rule.name == "maximal")
        #expect(rule.comment == "why this rule exists")
        #expect(rule.group == "scenario-a")
        #expect(rule.isEnabled == false)

        #expect(rule.match.urlPattern == "https://api\\.example\\.com/.*")
        #expect(rule.match.style == .regex)
        #expect(rule.match.isRegex)
        #expect(rule.match.isExact == false)
        #expect(rule.match.hostPattern == "*.example.com")
        #expect(rule.match.query == ["v": .equals("2")])
        #expect(rule.match.sourceApp == "com.example.app")
        #expect(rule.match.deviceIP == "192.168.1.42")
        #expect(rule.match.methods == ["GET", "POST"])

        guard case let .mock(mock) = rule.actions.route else {
            Issue.record("expected a mock route, got \(rule.actions.route)")
            return
        }
        #expect(mock.statusCode == 418)
        #expect(mock.headers == [HeaderPair(name: "X-Mock", value: "yes")])
        #expect(mock.body == .text("mocked"))
        #expect(mock.contentType == "application/json")

        let rewriteRequest = try #require(rule.actions.rewriteRequest)
        #expect(rewriteRequest.method == "PUT")
        #expect(rewriteRequest.url == "https://api.example.com/v2/home")
        #expect(rewriteRequest.setHeaders == [HeaderPair(name: "X-Req", value: "1")])
        #expect(rewriteRequest.removeHeaders == ["Cookie"])
        #expect(rewriteRequest.body == .text("req-body"))

        let rewriteResponse = try #require(rule.actions.rewriteResponse)
        #expect(rewriteResponse.statusCode == 503)
        #expect(rewriteResponse.setHeaders == [HeaderPair(name: "X-Res", value: "2")])
        #expect(rewriteResponse.removeHeaders == ["Set-Cookie"])
        #expect(rewriteResponse.bodyText == "res-body")

        let requestSub = try #require(rule.actions.requestSubstitutions.first)
        #expect(requestSub.field == .url)
        #expect(requestSub.match == "a")
        #expect(requestSub.replacement == "b")
        #expect(requestSub.isRegex == false)
        #expect(requestSub.caseSensitive)

        let responseSub = try #require(rule.actions.responseSubstitutions.first)
        #expect(responseSub.field == .body)
        #expect(responseSub.isRegex)
        #expect(responseSub.caseSensitive == false)

        #expect(rule.actions.delayMilliseconds == 250)
        #expect(rule.actions.dropFromCapture)
    }

    /// The four match styles, each spelled the way an agent would. The older
    /// boolean spellings map onto the same enum — `is_regex` beating `is_exact`,
    /// which is the precedence the old two-boolean matcher had — and a bare
    /// pattern still infers glob-or-prefix from its own `*`.
    @Test func everyMatchStyle_survivesTheCodec() async throws {
        let cases: [(input: [String: Any], expected: MatchStyle)] = [
            (["url_pattern": "https://a/x", "match_style": "prefix"], .prefix),
            (["url_pattern": "https://a/*", "match_style": "glob"], .glob),
            (["url_pattern": "https://a/x", "match_style": "exact"], .exact),
            (["url_pattern": "https://a/.*", "match_style": "regex"], .regex),
            (["url_pattern": "https://a/x", "is_regex": true], .regex),
            (["url_pattern": "https://a/x", "is_exact": true], .exact),
            (["url_pattern": "https://a/x", "is_regex": true, "is_exact": true], .regex),
            (["url_pattern": "https://a/*"], .glob),
            (["url_pattern": "https://a/x"], .prefix),
            // The state the two booleans could not express at all: a literal `*`
            // that must not be read as a wildcard.
            (["url_pattern": "https://a/*", "match_style": "prefix"], .prefix),
        ]
        for (input, expected) in cases {
            let engine = StubEngine()
            let executor = makeExecutor(engine)
            _ = try await executor.call(name: "set_rule", arguments: [
                "name": "styled", "match": input, "actions": ["block": true],
            ])
            let rule = try #require(engine.rules.rules.last)
            #expect(rule.match.style == expected, "input \(input) should have parsed as \(expected)")

            let json = try #require(try JSONSerialization.jsonObject(
                with: Data(try await executor.call(name: "list_rules", arguments: ["id": rule.id.uuidString]).utf8)
            ) as? [String: Any])
            let match = try #require(json["match"] as? [String: Any])
            #expect(match["matchStyle"] as? String == expected.rawValue, "the style must read back")
        }
    }

    /// A header substitution can name its target, which is the middle ground the
    /// model had no room for: blunter than "every header value", cheaper than
    /// overwriting the whole header through `rewrite_request.set_headers`.
    @Test func headerSubstitution_carriesItsTargetBothWays() async throws {
        let engine = StubEngine()
        let executor = makeExecutor(engine)
        _ = try await executor.call(name: "set_rule", arguments: [
            "name": "targeted", "match": ["url_pattern": "https://a/x"],
            "actions": ["request_substitutions": [
                ["field": "header", "header_name": "Authorization", "match": "old", "replacement": "new"],
                ["field": "header", "match": "old", "replacement": "new"],
            ]],
        ])
        let rule = try #require(engine.rules.rules.last)
        #expect(rule.actions.requestSubstitutions.first?.field == .header(name: "Authorization"))
        #expect(rule.actions.requestSubstitutions.last?.field == .header(), "no target means every header")

        let json = try #require(try JSONSerialization.jsonObject(
            with: Data(try await executor.call(name: "list_rules", arguments: ["id": rule.id.uuidString]).utf8)
        ) as? [String: Any])
        let subs = try #require(((json["actions"] as? [String: Any])?["requestSubstitutions"]) as? [[String: Any]])
        #expect(subs.first?["headerName"] as? String == "Authorization")
        #expect(subs.last?["headerName"] == nil, "absent is what untargeted looks like")
    }

    @Test func queryPredicates_bothSpellings_surviveTheCodec() async throws {
        let engine = StubEngine()
        let executor = makeExecutor(engine)
        _ = try await executor.call(name: "set_rule", arguments: [
            "name": "queried",
            "match": ["url_pattern": "https://a/x", "query": [
                "v": "2",
                "token": "*",
                "flag": ["equals": "*"], // the one the sentinel cannot say
            ]],
            "actions": ["block": true],
        ])
        let rule = try #require(engine.rules.rules.last)
        #expect(rule.match.query == ["v": .equals("2"), "token": .present, "flag": .equals("*")])

        let json = try #require(try JSONSerialization.jsonObject(
            with: Data(try await executor.call(name: "list_rules", arguments: ["id": rule.id.uuidString]).utf8)
        ) as? [String: Any])
        let query = try #require((json["match"] as? [String: Any])?["query"] as? [String: Any])
        #expect(query["v"] as? String == "2")
        #expect(query["token"] as? String == "*")
        #expect((query["flag"] as? [String: Any])?["equals"] as? String == "*")
    }

    /// A request body from a file: the other `RewriteBody` case, which the maximal
    /// input above can't also carry (one body, one case).
    @Test func requestBodyFile_survivesTheCodec_andOutranksInlineText() async throws {
        let engine = StubEngine()
        let executor = makeExecutor(engine)
        _ = try await executor.call(name: "set_rule", arguments: [
            "name": "filed", "match": ["url_pattern": "https://a/x"],
            "actions": ["rewrite_request": ["body": "ignored", "body_file": "/tmp/loom-fixture.json"]],
        ])
        let rule = try #require(engine.rules.rules.last)
        #expect(rule.actions.rewriteRequest?.body == .file(path: "/tmp/loom-fixture.json"))
        #expect(rule.actions.rewriteRequest?.bodyText == nil, "one body, not two")

        let json = try #require(try JSONSerialization.jsonObject(
            with: Data(try await executor.call(name: "list_rules", arguments: ["id": rule.id.uuidString]).utf8)
        ) as? [String: Any])
        let rewrite = try #require(((json["actions"] as? [String: Any])?["rewriteRequest"]) as? [String: Any])
        #expect(rewrite["bodyFile"] as? String == "/tmp/loom-fixture.json")
        #expect(rewrite["body"] == nil)
    }

    @Test func headerName_onANonHeaderField_isRefused() async {
        do {
            _ = try await makeExecutor(StubEngine()).call(name: "set_rule", arguments: [
                "name": "bad", "match": ["url_pattern": "https://a/x"],
                "actions": ["request_substitutions": [
                    ["field": "body", "header_name": "Authorization", "match": "a"],
                ]],
            ])
            Issue.record("expected invalid params")
        } catch let error as MCPError {
            #expect("\(error)".contains("header_name"))
        } catch { Issue.record("expected MCPError, got \(error)") }
    }

    /// A binary mock body: base64 in, base64 out, and — since a mock has exactly
    /// one body now — base64 wins when a caller sends both, at the one boundary
    /// that can receive both.
    @Test func binaryMockBody_survivesTheCodec_andOutranksText() async throws {
        let engine = StubEngine()
        let executor = makeExecutor(engine)
        let base64 = Data("bin".utf8).base64EncodedString()
        _ = try await executor.call(name: "set_rule", arguments: [
            "name": "binary", "match": ["url_pattern": "https://a/x"],
            "actions": ["mock_response": ["body": "ignored", "body_base64": base64]],
        ])
        let rule = try #require(engine.rules.rules.last)
        guard case let .mock(mock) = rule.actions.route else {
            Issue.record("expected a mock route")
            return
        }
        #expect(mock.body == .bytes(Data("bin".utf8)))
        #expect(mock.bodyText == nil, "one body, not two")
        #expect(mock.resolvedBody() == Data("bin".utf8))

        let json = try #require(try JSONSerialization.jsonObject(
            with: Data(try await executor.call(name: "list_rules", arguments: ["id": rule.id.uuidString]).utf8)
        ) as? [String: Any])
        let rendered = try #require(((json["actions"] as? [String: Any])?["mockResponse"]) as? [String: Any])
        #expect(rendered["bodyBase64"] as? String == base64)
    }

    /// Undecodable base64 is refused where the offending string still exists to
    /// name — the model holds bytes, so it would otherwise land as an empty body.
    @Test func invalidBase64MockBody_isRefused() async {
        do {
            _ = try await makeExecutor(StubEngine()).call(name: "set_rule", arguments: [
                "name": "bad", "match": ["url_pattern": "https://a/x"],
                "actions": ["mock_response": ["body_base64": "not base64!!!"]],
            ])
            Issue.record("expected invalid params")
        } catch let error as MCPError {
            #expect("\(error)".contains("base64"))
        } catch { Issue.record("expected MCPError, got \(error)") }
    }

    @Test func everyRouteCase_survivesInputToStoredRule() async throws {
        for route in allRoutes {
            let (rule, _, _) = try await storedRule(for: route)
            // Same case as asked for — a route the parser drops would land as
            // `.passthrough` (the codec's silent failure mode).
            #expect(
                Self.routeCaseName(rule.actions.route) == Self.routeCaseName(route),
                "route \(Self.routeCaseName(route)) did not survive the codec"
            )
        }
    }

    private static func routeCaseName(_ route: Route) -> String {
        switch route {
        case .passthrough: return "passthrough"
        case .block: return "block"
        case .mock: return "mock"
        case .mapLocal: return "mapLocal"
        case .mapRemote: return "mapRemote"
        }
    }

    // MARK: - One match, two surfaces

    /// A `RuleMatch` is scoping vocabulary shared by rules and breakpoints, and an
    /// agent reads it back from both. It used to be *rendered* twice — identical
    /// code in `rule(...)` and in `matchDict` — so a predicate added to one copy
    /// would have made the same scoping read differently depending on which tool
    /// you asked. Both now go through `matchDict`; this pins that, because the way
    /// the duplication would come back is someone re-inlining one of them.
    @Test func aMatchRendersIdentically_forARuleAndForABreakpoint() async throws {
        let engine = StubEngine()
        let executor = makeExecutor(engine)

        // Every predicate the model has, so a field rendered by only one surface
        // shows up as a difference rather than as two equally-empty objects.
        let match: [String: Any] = [
            "url_pattern": "https://api\\.example\\.com/.*",
            "is_regex": true,
            "host_pattern": "*.example.com",
            "query": ["v": "2"],
            "source_app": "com.example.app",
            "device_ip": "192.168.1.42",
            "methods": ["GET", "POST"],
        ]
        _ = try await executor.call(name: "set_rule", arguments: [
            "name": "scoped", "match": match, "actions": ["block": true],
        ])
        let rule = try #require(engine.rules.rules.last)
        let ruleJSON = try #require(try JSONSerialization.jsonObject(
            with: Data(try await executor.call(name: "list_rules", arguments: ["id": rule.id.uuidString]).utf8)
        ) as? [String: Any])

        let breakpointJSON = try #require(try JSONSerialization.jsonObject(
            with: Data(try await executor.call(name: "arm_breakpoint", arguments: ["match": match]).utf8)
        ) as? [String: Any])

        let fromRule = try #require(ruleJSON["match"] as? [String: Any])
        let fromBreakpoint = try #require(breakpointJSON["match"] as? [String: Any])
        #expect(
            NSDictionary(dictionary: fromRule) == NSDictionary(dictionary: fromBreakpoint),
            "the same match reads differently as a rule (\(fromRule)) and as a breakpoint (\(fromBreakpoint))"
        )
        // Not vacuous: the shared render must actually carry the predicates.
        #expect(fromRule["hostPattern"] as? String == "*.example.com")
        #expect(fromRule["deviceIP"] as? String == "192.168.1.42")
    }

    // MARK: - Census: the model's fields vs. the two hand-written surfaces

    /// Field names the model encodes but the **input schema** deliberately doesn't
    /// advertise, and why. A new model field is not allowed to join this list by
    /// accident — it has to be written down here.
    private static let schemaOmissions: [String: String] = [
        "createdAt": "server-stamped on create; an agent-supplied creation time would be a lie",
        "route": "The route is not an object on the wire — it is implied by which of block/mock_response/map_remote/map_local is present, and set_rule rejects more than one.",
        "type": "Route's Codable discriminator, which the flattened wire shape above has no need for.",
    ]

    /// Field names the model encodes but the **render** deliberately doesn't emit.
    private static let renderOmissions: [String: String] = [
        "type": "Route's Codable discriminator; the render flattens it into the actions key (actions.mockResponse, actions.mapRemote, …).",
        "route": "Flattened for the same reason — there is no `route` object in the rendered actions.",
    ]

    /// camelCase model field → its wire name, where mechanical snake_casing is wrong.
    private static let schemaAliases: [String: String] = [
        "isEnabled": "enabled",
        "style": "match_style",
        // `MockBody`'s two cases: one model field (`body`), two wire keys.
        "text": "body",
        "bytes": "body_base64",
        "bodyText": "body",
        "delayMilliseconds": "delay_ms",
        "excludePattern": "exclude",
        "mock": "mock_response",
    ]

    /// camelCase model field → rendered key, where they differ.
    private static let renderAliases: [String: String] = [
        "isEnabled": "enabled",
        "style": "matchStyle",
        "text": "body",
        "bytes": "bodyBase64",
        "bodyText": "body",
        "delayMilliseconds": "delayMs",
        "excludePattern": "exclude",
        "mock": "mockResponse",
    ]

    @Test func inputSchema_advertisesEveryModelField() async throws {
        let schemaKeys = try Self.schemaPropertyNames()
        for field in try await modelFieldNames() {
            let expected = Self.schemaAliases[field] ?? Self.snakeCased(field)
            if schemaKeys.contains(expected) { continue }
            if let reason = Self.schemaOmissions[field] {
                #expect(reason.count > 20, "\(field): omission needs a real reason")
                continue
            }
            Issue.record("""
            TrafficRule field `\(field)` has no `set_rule` schema property \
            (expected `\(expected)`). Either advertise it or record it in \
            `schemaOmissions` with a reason — an agent cannot set what the schema \
            never mentions.
            """)
        }
    }

    @Test func render_emitsEveryModelField() async throws {
        var renderedKeys: Set<String> = []
        for route in allRoutes {
            let (rule, executor, _) = try await storedRule(for: route)
            let json = try await executor.call(name: "list_rules", arguments: ["id": rule.id.uuidString])
            let object = try #require(
                try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
            )
            renderedKeys.formUnion(Self.keyNames(in: object))
        }

        for field in try await modelFieldNames() {
            let expected = Self.renderAliases[field] ?? field
            if renderedKeys.contains(expected) { continue }
            if let reason = Self.renderOmissions[field] {
                #expect(reason.count > 20, "\(field): omission needs a real reason")
                continue
            }
            Issue.record("""
            TrafficRule field `\(field)` never appears in the `list_rules` render \
            (expected `\(expected)`). Either render it or record it in \
            `renderOmissions` with a reason — an agent cannot read back what the \
            render drops, and neither can the human reading the same rule.
            """)
        }
    }

    // MARK: - Census plumbing

    /// Every stored property of `TrafficRule` and everything it holds, across all
    /// route cases. Reflection, deliberately, **not** the Codable encoding: a
    /// freshly-added `var probe: String?` is absent from the JSON whenever it is
    /// nil, so an encoding-based census silently blesses exactly the drift this
    /// suite exists to catch. `Mirror` reports the property either way.
    private func modelFieldNames() async throws -> Set<String> {
        var names: Set<String> = []
        for route in allRoutes {
            let (rule, _, _) = try await storedRule(for: route)
            names.formUnion(Self.fieldNames(of: rule))
        }
        return names
    }

    /// Values whose internals are not model structure — recursing into `UUID`
    /// exposes its `uuid` byte tuple, into `Date` its `timeIntervalSince…`, and so on.
    private static func isLeaf(_ value: Any) -> Bool {
        value is String || value is Int || value is Bool || value is Double
            || value is UUID || value is Date || value is Data
    }

    private static func fieldNames(of value: Any) -> Set<String> {
        if isLeaf(value) { return [] }
        var names: Set<String> = []
        let mirror = Mirror(reflecting: value)
        switch mirror.displayStyle {
        case .dictionary:
            return [] // free-form data: keys are values, not fields
        case .optional:
            // `nil` has no child, which is fine — the label was recorded by the
            // parent before it recursed here.
            if let wrapped = mirror.children.first?.value {
                names.formUnion(fieldNames(of: wrapped))
            }
        default:
            for child in mirror.children {
                guard let label = child.label, !label.isEmpty else {
                    names.formUnion(fieldNames(of: child.value)) // collection element
                    continue
                }
                names.insert(label)
                guard !freeFormContainers.contains(label) else { continue }
                names.formUnion(fieldNames(of: child.value))
            }
        }
        return names
    }

    /// Keys whose *contents* are user data, not model fields — walking into them
    /// would treat a header name or a query parameter as a field of the model.
    /// (It also means `HeaderPair`'s own `name`/`value` never reach the census;
    /// both surfaces represent headers as a name→value object rather than as a
    /// list of pairs, so there is nothing to compare.)
    private static let freeFormContainers: Set<String> = ["query", "headers", "setHeaders"]

    /// Recursively collect dictionary key names, optionally not descending into
    /// free-form containers (whose keys are data).
    private static func keyNames(
        in value: Any,
        skippingValuesOf skipped: Set<String> = []
    ) -> Set<String> {
        var names: Set<String> = []
        switch value {
        case let dictionary as [String: Any]:
            for (key, nested) in dictionary {
                names.insert(key)
                if skipped.contains(key) { continue }
                names.formUnion(keyNames(in: nested, skippingValuesOf: skipped))
            }
        case let array as [Any]:
            for element in array {
                names.formUnion(keyNames(in: element, skippingValuesOf: skipped))
            }
        default:
            break
        }
        return names
    }

    /// Property names anywhere in `set_rule`'s input schema, recursively — the
    /// schema is nested (`match`, `actions`, `actions.mock_response`, …), and a
    /// flat census is what lets it be compared against a flat field list.
    private static func schemaPropertyNames() throws -> Set<String> {
        let executor = MCPToolExecutor(engine: StubEngine(), appVersion: "9.9", protocolVersion: "x")
        let definition = try #require(
            executor.toolDefinitions.first { $0["name"] as? String == "set_rule" }
        )
        let schema = try #require(definition["inputSchema"] as? [String: Any])
        return propertyNames(in: schema)
    }

    /// Walk a JSON Schema, collecting only `properties` keys (so schema keywords
    /// like `type` / `description` / `items` never masquerade as field names).
    private static func propertyNames(in schema: [String: Any]) -> Set<String> {
        var names: Set<String> = []
        if let properties = schema["properties"] as? [String: Any] {
            for (name, nested) in properties {
                names.insert(name)
                if let nested = nested as? [String: Any] {
                    names.formUnion(propertyNames(in: nested))
                }
            }
        }
        if let items = schema["items"] as? [String: Any] {
            names.formUnion(propertyNames(in: items))
        }
        return names
    }

    /// `deviceIP` → `device_ip`, `isRegex` → `is_regex`: lowercase runs of capitals
    /// as one word so an acronym doesn't become `device_i_p`.
    static func snakeCased(_ name: String) -> String {
        var out = ""
        var previousWasUpper = false
        for (offset, character) in name.enumerated() {
            if character.isUppercase {
                let nextIsLower = name.index(name.startIndex, offsetBy: offset + 1) < name.endIndex
                    && name[name.index(name.startIndex, offsetBy: offset + 1)].isLowercase
                if offset > 0, !previousWasUpper || nextIsLower { out.append("_") }
                out.append(Character(character.lowercased()))
                previousWasUpper = true
            } else {
                out.append(character)
                previousWasUpper = false
            }
        }
        return out
    }

    @Test(arguments: [
        ("deviceIP", "device_ip"),
        ("isRegex", "is_regex"),
        ("urlPattern", "url_pattern"),
        ("keepHostHeader", "keep_host_header"),
        ("path", "path"),
    ])
    func snakeCasing(input: String, expected: String) {
        #expect(Self.snakeCased(input) == expected)
    }
}
