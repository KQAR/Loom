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
    private func actionsInput(for route: Route) -> [String: Any] {
        var actions: [String: Any] = [
            "rewrite_request": [
                "method": "PUT",
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
                "body_base64": Data("bin".utf8).base64EncodedString(),
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

    private func maximalInput(for route: Route) -> [String: Any] {
        // `is_regex` and `is_exact` are alternatives, and the render only emits each
        // when true — so one route variant matches exactly and the rest by regex,
        // which is what makes the union of renders cover both fields.
        let exactVariant = Self.routeCaseName(route) == "block"
        return [
            "name": "maximal",
            "comment": "why this rule exists",
            "group": "scenario-a",
            "enabled": false,
            "match": [
                "url_pattern": exactVariant
                    ? "https://api.example.com/v1/home"
                    : "https://api\\.example\\.com/.*",
                "is_regex": !exactVariant,
                "is_exact": exactVariant,
                "host_pattern": "*.example.com",
                "query": ["v": "2"],
                "source_app": "com.example.app",
                "device_ip": "192.168.1.42",
                "methods": ["GET", "POST"],
            ],
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
        #expect(rule.match.isRegex)
        #expect(rule.match.isExact == false)
        #expect(rule.match.hostPattern == "*.example.com")
        #expect(rule.match.query == ["v": "2"])
        #expect(rule.match.sourceApp == "com.example.app")
        #expect(rule.match.deviceIP == "192.168.1.42")
        #expect(rule.match.methods == ["GET", "POST"])

        guard case let .mock(mock) = rule.actions.route else {
            Issue.record("expected a mock route, got \(rule.actions.route)")
            return
        }
        #expect(mock.statusCode == 418)
        #expect(mock.headers == [HeaderPair(name: "X-Mock", value: "yes")])
        #expect(mock.bodyText == "mocked")
        #expect(mock.bodyBase64 == Data("bin".utf8).base64EncodedString())
        #expect(mock.contentType == "application/json")

        let rewriteRequest = try #require(rule.actions.rewriteRequest)
        #expect(rewriteRequest.method == "PUT")
        #expect(rewriteRequest.setHeaders == [HeaderPair(name: "X-Req", value: "1")])
        #expect(rewriteRequest.removeHeaders == ["Cookie"])
        #expect(rewriteRequest.bodyText == "req-body")

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
        "bodyText": "body",
        "delayMilliseconds": "delay_ms",
        "excludePattern": "exclude",
        "mock": "mock_response",
    ]

    /// camelCase model field → rendered key, where they differ.
    private static let renderAliases: [String: String] = [
        "isEnabled": "enabled",
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
