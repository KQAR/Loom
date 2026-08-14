import Foundation
import LoomSharedModels

/// Traffic-rule CRUD plus the hand-written codec between the wire shape
/// (snake_case in, camelCase out) and `TrafficRule`.
///
/// The codec is hand-written on purpose — the input and output shapes differ
/// deliberately — which is exactly why `RuleCodecParityTests` takes a census of
/// the model's fields and fails when one of them stops being settable or
/// readable here.
extension MCPToolExecutor {
    /// `list_rules`: all rules (bodies truncated), or — with `id` — one rule with
    /// full bodies. Absorbs the former `get_rule`.
    func handleListRules(_ arguments: MCPArguments) async throws -> String {
        let state = await engine.rulesState()
        if arguments.has("id") {
            let rule = try await existingRule(arguments)
            return prettyJSON(Self.rule(
                rule, truncateBodies: false, dropped: state.droppedCounts[rule.id]
            ))
        }
        var out: [String: Any] = [
            "enabled": state.enabled,
            "count": state.rules.count,
            "rules": state.rules.map {
                Self.rule($0, truncateBodies: true, dropped: state.droppedCounts[$0.id])
            },
        ]
        // Only when something is switched off: a group switch is the third reason
        // an enabled-looking rule does nothing, and it is invisible on the rule
        // itself. `null` is the ungrouped bucket.
        if !state.disabledGroups.isEmpty {
            out["disabledGroups"] = state.disabledGroups.map { $0 as Any? ?? NSNull() }
        }
        return prettyJSON(out)
    }

    /// `set_rule`: upsert. No `id` → create (name/match/actions required); `id` →
    /// update (provided fields replace). Absorbs `create_rule` + `update_rule`.
    func handleSetRule(_ arguments: MCPArguments) async throws -> String {
        arguments.has("id")
            ? try await updateRule(arguments)
            : try await createRule(arguments)
    }

    func createRule(_ arguments: MCPArguments) async throws -> String {
        let ruleName = try arguments.requiredString("name", "required to create a rule")
        guard let matchRaw = try arguments.object("match"),
              let match = try Self.ruleMatch(from: matchRaw) else {
            throw MCPError.invalidParams("`match` with `url_pattern` is required")
        }
        guard let actionsRaw = try arguments.object("actions") else {
            throw MCPError.invalidParams("`actions` is required")
        }
        let rule = TrafficRule(
            name: ruleName,
            comment: try arguments.string("comment"),
            group: try Self.groupName(arguments, "group"),
            isEnabled: try arguments.bool("enabled", or: true),
            match: match,
            actions: try Self.ruleActions(from: actionsRaw)
        )
        do {
            try await engine.addRule(rule)
        } catch let error as ProxyControlError {
            throw MCPToolFailure(error.message)
        }
        return prettyJSON(await writtenRule(rule))
    }

    func updateRule(_ arguments: MCPArguments) async throws -> String {
        var rule = try await existingRule(arguments)
        if let newName = try arguments.string("name") { rule.name = newName }
        if let comment = try arguments.string("comment") { rule.comment = comment }
        // Present-but-empty is how a rule is ungrouped, so this asks whether the key
        // was sent rather than whether it parsed to a group name.
        if arguments.has("group") { rule.group = try Self.groupName(arguments, "group") }
        if let enabled = try arguments.bool("enabled") { rule.isEnabled = enabled }
        if let matchRaw = try arguments.object("match") {
            guard let match = try Self.ruleMatch(from: matchRaw) else {
                throw MCPError.invalidParams("`match` must contain `url_pattern`")
            }
            rule.match = match
        }
        if let actionsRaw = try arguments.object("actions") {
            rule.actions = try Self.ruleActions(from: actionsRaw)
        }
        do {
            try await engine.updateRule(rule)
        } catch let error as ProxyControlError {
            throw MCPToolFailure(error.message)
        }
        return prettyJSON(await writtenRule(rule))
    }

    /// A just-written rule, rendered, plus whether it will actually affect traffic.
    ///
    /// Without this the reply is indistinguishable from a rule that is live: it
    /// echoes the rule back with its own `enabled: true`, which reads as
    /// confirmation. If the master switch happens to be off, nothing in the
    /// exchange says so — no error, no warning — and the agent reports a mock that
    /// silently never fires. `effective` is always present, so its absence can't be
    /// mistaken for "fine"; the reason names the tool that fixes it.
    func writtenRule(_ rule: TrafficRule) async -> [String: Any] {
        var out = Self.rule(rule, truncateBodies: false)
        // One definition of "why isn't this applying", on the model, so the three
        // switches (master / group / rule) can't be enumerated differently here
        // than anywhere else — the group one was missing entirely, which made a
        // rule written into a switched-off group report `effective: true`.
        let reason = await engine.rulesState().ineffectiveReason(for: rule)
        out["effective"] = reason == nil
        if let reason { out["ineffectiveReason"] = reason }
        // A body that was meant to be JSON and isn't gets written as asked — a
        // malformed payload is a legitimate thing to mock — but never silently
        // (`MCPBodyWarnings`).
        Self.attach(warnings: Self.bodyWarnings(for: rule.actions), to: &out)
        return out
    }

    func handleDeleteRule(_ arguments: MCPArguments) async throws -> String {
        let rule = try await existingRule(arguments)
        do {
            try await engine.deleteRule(id: rule.id)
        } catch let error as ProxyControlError {
            throw MCPToolFailure(error.message)
        }
        return prettyJSON(["deleted": rule.id.uuidString, "name": rule.name])
    }

    func handleSetRulesEnabled(_ arguments: MCPArguments) async throws -> String {
        let enabled = try arguments.requiredBool("enabled")
        await engine.setRulesEnabled(enabled)
        let state = await engine.rulesState()
        return prettyJSON(["enabled": state.enabled, "count": state.rules.count])
    }

    func handleSetGroupEnabled(_ arguments: MCPArguments) async throws -> String {
        guard let group = try Self.groupName(arguments, "group") else {
            throw MCPError.invalidParams("`group` (non-empty string) is required")
        }
        let enabled = try arguments.requiredBool("enabled")
        let members = await engine.rulesState().rules.filter { $0.group == group }
        guard !members.isEmpty else {
            throw MCPToolFailure("no rules in group \"\(group)\" — see list_rules")
        }
        await engine.setGroupEnabled(group: group, enabled: enabled)
        let state = await engine.rulesState()
        var out: [String: Any] = ["group": group, "enabled": enabled, "members": members.count]
        // The group switch is its own axis now, so "how many of this group's rules
        // are actually live" is no longer implied by `affected` — a member the
        // human turned off individually stays off, which is the point of the
        // change and is exactly what an agent would otherwise misreport.
        out["active"] = state.activeRules.filter { $0.group == group }.count
        let masterEnabled = state.enabled
        out["effective"] = masterEnabled && enabled
        if enabled, !masterEnabled {
            out["ineffectiveReason"] = """
            The rules master switch is off, so no rule applies to traffic — including \
            this group. Turn it on with set_rules_enabled(enabled: true).
            """
        }
        return prettyJSON(out)
    }

    /// Resolve the `id` argument to a stored rule or throw a structured error.
    func existingRule(_ arguments: MCPArguments) async throws -> TrafficRule {
        let id = try arguments.requiredUUID("id", "a rule UUID string")
        guard let rule = await engine.rulesState().rules.first(where: { $0.id == id }) else {
            throw MCPToolFailure("no rule with id \(id.uuidString)")
        }
        return rule
    }

    // MARK: - Rules parsing / rendering

    /// Normalize a group argument: empty or whitespace means "no group". A
    /// wrong-typed value is an error now rather than the same answer as an absent one
    /// — `group: 3` used to silently ungroup the rule.
    static func groupName(_ arguments: MCPArguments, _ key: String) throws -> String? {
        guard let name = try arguments.string(key)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty
        else { return nil }
        return name
    }

    /// The wire keeps three ways to say the same thing, because two of them are
    /// what every agent already sends: `match_style` (the model's own vocabulary),
    /// and the older `is_regex` / `is_exact` booleans. They collapse to one
    /// `MatchStyle` here — the one place that can receive the illegal combination
    /// — with regex beating exact, as the old matcher did.
    static func matchStyle(from raw: MCPArguments) throws -> MatchStyle? {
        if let style = try raw.option("match_style", MatchStyle.self) { return style }
        if try raw.bool("is_regex", or: false) { return .regex }
        if try raw.bool("is_exact", or: false) { return .exact }
        return nil // let the pattern speak: `*` → glob, else prefix
    }

    static func ruleMatch(from raw: MCPArguments) throws -> RuleMatch? {
        guard let pattern = try raw.string("url_pattern") else { return nil }
        return RuleMatch(
            urlPattern: pattern,
            style: try matchStyle(from: raw),
            methods: try raw.stringArray("methods") ?? [],
            hostPattern: try raw.string("host_pattern").flatMap { $0.isEmpty ? nil : $0 },
            query: try queryPredicates(raw, "query"),
            sourceApp: try raw.string("source_app").flatMap { $0.isEmpty ? nil : $0 },
            deviceIP: try raw.string("device_ip").flatMap { $0.isEmpty ? nil : $0 }
        )
    }

    /// Query predicates, either spelling. `{"v": "2"}` with `*` for "any value" is
    /// what every agent already sends; `{"v": {"equals": "*"}}` is how a parameter
    /// whose value really is `*` gets said, which the sentinel alone cannot.
    static func queryPredicates(_ arguments: MCPArguments, _ key: String) throws -> [String: QueryPredicate]? {
        guard let dict = try arguments.rawObject(key), !dict.isEmpty else { return nil }
        var out: [String: QueryPredicate] = [:]
        for (name, value) in dict {
            switch value {
            case let .string(text):
                out[name] = QueryPredicate(legacyWireValue: text)
            case let .object(object):
                if case let .string(equals)? = object["equals"] { out[name] = .equals(equals) }
                else if object["present"] == .bool(true) { out[name] = .present }
            default:
                break
            }
        }
        return out.isEmpty ? nil : out
    }

    static func ruleActions(from raw: MCPArguments) throws -> RuleActions {
        var actions = RuleActions()

        // The route is exactly one of block/mock/map_remote/map_local. Reject more
        // than one rather than silently picking — the AI must see the conflict.
        var routes: [Route] = []
        if try raw.bool("block", or: false) { routes.append(.block) }
        if let mock = try raw.object("mock_response") {
            let base64 = try mock.string("body_base64")
            // Refused here, where the offending string still exists to quote: the
            // model holds decoded bytes, so an undecodable payload would otherwise
            // become a silently empty body.
            if let base64, Data(base64Encoded: base64) == nil {
                throw MCPError.invalidParams("mock_response.body_base64 is not valid base64")
            }
            routes.append(.mock(MockResponseAction.fromWire(
                statusCode: try mock.int("status_code", or: 200),
                headers: try wireHeaders(mock, "headers"),
                bodyText: try mock.string("body"),
                bodyBase64: base64,
                contentType: try mock.string("content_type")
            )))
        }
        if let map = try raw.object("map_remote") {
            let destination = try map.requiredString("destination", "a non-empty origin")
            guard !destination.isEmpty else {
                throw MCPError.invalidParams("map_remote requires a non-empty `destination`")
            }
            routes.append(.mapRemote(MapRemoteAction(
                destination: destination,
                excludePattern: try map.string("exclude").flatMap { $0.isEmpty ? nil : $0 },
                keepHostHeader: try map.bool("keep_host_header", or: false)
            )))
        }
        if let map = try raw.object("map_local") {
            let path = try map.requiredString("path", "a non-empty absolute file path")
            guard !path.isEmpty else {
                throw MCPError.invalidParams("map_local requires a non-empty `path`")
            }
            routes.append(.mapLocal(MapLocalAction(
                path: path,
                statusCode: try map.int("status_code", or: 200),
                contentType: try map.string("content_type")
            )))
        }
        guard routes.count <= 1 else {
            throw MCPError.invalidParams("set at most one of block/mock_response/map_remote/map_local")
        }
        actions.route = routes.first ?? .passthrough

        if let rewrite = try raw.object("rewrite_request") {
            // One body, two spellings on the wire; the boundary that can receive
            // both is where the choice is made, and a file outranks inline text.
            let body: RewriteBody?
            if let path = try rewrite.string("body_file"), !path.isEmpty {
                body = .file(path: path)
            } else if let text = try rewrite.string("body") {
                body = .text(text)
            } else {
                body = nil
            }
            actions.rewriteRequest = RequestRewriteAction(
                method: try rewrite.string("method"),
                url: try rewrite.string("url").flatMap { $0.isEmpty ? nil : $0 },
                setHeaders: try wireHeaders(rewrite, "set_headers"),
                removeHeaders: try rewrite.stringArray("remove_headers") ?? [],
                body: body
            )
        }
        if let rewrite = try raw.object("rewrite_response") {
            actions.rewriteResponse = ResponseRewriteAction(
                statusCode: try rewrite.int("status_code"),
                setHeaders: try wireHeaders(rewrite, "set_headers"),
                removeHeaders: try rewrite.stringArray("remove_headers") ?? [],
                bodyText: try rewrite.string("body")
            )
        }
        actions.requestSubstitutions = try substitutions(raw, "request_substitutions")
        actions.responseSubstitutions = try substitutions(raw, "response_substitutions")
        actions.delayMilliseconds = try raw.int("delay_ms")
        actions.dropFromCapture = try raw.bool("drop_from_capture", or: false)
        return actions
    }

    /// Parse substitutions strictly: a malformed item (bad `field` enum, missing
    /// `match`) is an error, not a silently-dropped row — otherwise the AI is told
    /// the rule was created while the store holds less than it sent.
    static func substitutions(_ arguments: MCPArguments, _ key: String) throws -> [SubstitutionRule] {
        // A non-array (or an array of non-objects) throws out of `objects` naming the
        // key and the shape; absent means no substitutions, which is not an error.
        guard let items = try arguments.objects(key) else { return [] }
        return try items.map { item in
            guard let fieldRaw = try item.string("field") else {
                throw MCPError.invalidParams("\(key): each item needs a `field`")
            }
            guard let kind = SubstitutionRule.Field.Kind(rawValue: fieldRaw) else {
                throw MCPError.invalidParams("\(key): invalid field \"\(fieldRaw)\" (url/header/body)")
            }
            let headerName = try item.string("header_name")
            if headerName != nil, kind != .header {
                throw MCPError.invalidParams("\(key): header_name only applies to field \"header\"")
            }
            let field = SubstitutionRule.Field(kind: kind, headerName: headerName)
            guard let match = try item.string("match") else {
                throw MCPError.invalidParams("\(key): each item needs a `match` string")
            }
            return SubstitutionRule(
                field: field,
                match: match,
                replacement: try item.string("replacement", or: ""),
                isRegex: try item.bool("is_regex", or: false),
                caseSensitive: try item.bool("case_sensitive", or: false)
            )
        }
    }

    /// A free-form header map from one of the rule action objects. Named apart from
    /// `headerPairs(from:)` — the top-level `set_headers` of replay/resume — because
    /// they read different arguments at different depths, and one function pretending
    /// to be both is how a nested edit silently reads the outer key.
    static func wireHeaders(_ arguments: MCPArguments, _ key: String) throws -> [HeaderPair] {
        try arguments.stringMap(key)?.map { HeaderPair(name: $0.key, value: $0.value) } ?? []
    }

    static func rule(
        _ rule: TrafficRule, truncateBodies: Bool, dropped: Int? = nil
    ) -> [String: Any] {
        MCPRender.dict(RuleRender(rule, truncateBodies: truncateBodies, droppedFlows: dropped))
    }

    /// The one rendering of a `RuleMatch`, shared by `list_rules` and by the
    /// breakpoint tools — the two surfaces that show an agent what a match says.
    /// It was written twice, identically, and a predicate added to only one copy
    /// would have meant a rule and a breakpoint scoped the same way reading back
    /// differently. `RuleMatch` is already parsed once (`ruleMatch(from:)`) and
    /// advertised once (`matchSchema`); this closes the third side.
    static func matchDict(_ match: RuleMatch) -> [String: Any] {
        MCPRender.dict(RuleMatchRender(match))
    }
}
