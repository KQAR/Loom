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
    func handleListRules(_ arguments: [String: Any]) async throws -> String {
        if arguments["id"] != nil {
            let rule = try await existingRule(arguments)
            return prettyJSON(Self.rule(rule, truncateBodies: false))
        }
        let state = await engine.rulesState()
        var out: [String: Any] = [
            "enabled": state.enabled,
            "count": state.rules.count,
            "rules": state.rules.map { Self.rule($0, truncateBodies: true) },
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
    func handleSetRule(_ arguments: [String: Any]) async throws -> String {
        arguments["id"] == nil
            ? try await createRule(arguments)
            : try await updateRule(arguments)
    }

    func createRule(_ arguments: [String: Any]) async throws -> String {
        guard let ruleName = arguments["name"] as? String else {
            throw MCPError.invalidParams("`name` is required to create a rule")
        }
        guard let matchRaw = arguments["match"] as? [String: Any],
              let match = Self.ruleMatch(from: matchRaw) else {
            throw MCPError.invalidParams("`match` with `url_pattern` is required")
        }
        guard let actionsRaw = arguments["actions"] as? [String: Any] else {
            throw MCPError.invalidParams("`actions` is required")
        }
        let rule = TrafficRule(
            name: ruleName,
            comment: arguments["comment"] as? String,
            group: Self.groupName(arguments["group"]),
            isEnabled: (arguments["enabled"] as? Bool) ?? true,
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

    func updateRule(_ arguments: [String: Any]) async throws -> String {
        var rule = try await existingRule(arguments)
        if let newName = arguments["name"] as? String { rule.name = newName }
        if let comment = arguments["comment"] as? String { rule.comment = comment }
        if arguments["group"] is String { rule.group = Self.groupName(arguments["group"]) }
        if let enabled = arguments["enabled"] as? Bool { rule.isEnabled = enabled }
        if let matchRaw = arguments["match"] as? [String: Any] {
            guard let match = Self.ruleMatch(from: matchRaw) else {
                throw MCPError.invalidParams("`match` must contain `url_pattern`")
            }
            rule.match = match
        }
        if let actionsRaw = arguments["actions"] as? [String: Any] {
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

    func handleDeleteRule(_ arguments: [String: Any]) async throws -> String {
        let rule = try await existingRule(arguments)
        do {
            try await engine.deleteRule(id: rule.id)
        } catch let error as ProxyControlError {
            throw MCPToolFailure(error.message)
        }
        return prettyJSON(["deleted": rule.id.uuidString, "name": rule.name])
    }

    func handleSetRulesEnabled(_ arguments: [String: Any]) async throws -> String {
        guard let enabled = arguments["enabled"] as? Bool else {
            throw MCPError.invalidParams("`enabled` (boolean) is required")
        }
        await engine.setRulesEnabled(enabled)
        let state = await engine.rulesState()
        return prettyJSON(["enabled": state.enabled, "count": state.rules.count])
    }

    func handleSetGroupEnabled(_ arguments: [String: Any]) async throws -> String {
        guard let group = Self.groupName(arguments["group"]) else {
            throw MCPError.invalidParams("`group` (non-empty string) is required")
        }
        guard let enabled = arguments["enabled"] as? Bool else {
            throw MCPError.invalidParams("`enabled` (boolean) is required")
        }
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
    func existingRule(_ arguments: [String: Any]) async throws -> TrafficRule {
        guard let idString = arguments["id"] as? String, let id = UUID(uuidString: idString) else {
            throw MCPError.invalidParams("`id` must be a rule UUID string")
        }
        guard let rule = await engine.rulesState().rules.first(where: { $0.id == id }) else {
            throw MCPToolFailure("no rule with id \(idString)")
        }
        return rule
    }

    // MARK: - Rules parsing / rendering

    /// Normalize a group argument: empty/whitespace (or non-string) means "no group".
    static func groupName(_ raw: Any?) -> String? {
        guard let name = (raw as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !name.isEmpty else { return nil }
        return name
    }

    /// The wire keeps three ways to say the same thing, because two of them are
    /// what every agent already sends: `match_style` (the model's own vocabulary),
    /// and the older `is_regex` / `is_exact` booleans. They collapse to one
    /// `MatchStyle` here — the one place that can receive the illegal combination
    /// — with regex beating exact, as the old matcher did.
    static func matchStyle(from raw: [String: Any]) -> MatchStyle? {
        if let named = raw["match_style"] as? String, let style = MatchStyle(rawValue: named) {
            return style
        }
        if (raw["is_regex"] as? Bool) == true { return .regex }
        if (raw["is_exact"] as? Bool) == true { return .exact }
        return nil // let the pattern speak: `*` → glob, else prefix
    }

    static func ruleMatch(from raw: [String: Any]) -> RuleMatch? {
        guard let pattern = raw["url_pattern"] as? String else { return nil }
        return RuleMatch(
            urlPattern: pattern,
            style: matchStyle(from: raw),
            methods: (raw["methods"] as? [String]) ?? [],
            hostPattern: (raw["host_pattern"] as? String).flatMap { $0.isEmpty ? nil : $0 },
            query: queryPredicates(raw["query"]),
            sourceApp: (raw["source_app"] as? String).flatMap { $0.isEmpty ? nil : $0 },
            deviceIP: (raw["device_ip"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        )
    }

    /// Query predicates, either spelling. `{"v": "2"}` with `*` for "any value" is
    /// what every agent already sends; `{"v": {"equals": "*"}}` is how a parameter
    /// whose value really is `*` gets said, which the sentinel alone cannot.
    static func queryPredicates(_ raw: Any?) -> [String: QueryPredicate]? {
        guard let dict = raw as? [String: Any], !dict.isEmpty else { return nil }
        var out: [String: QueryPredicate] = [:]
        for (key, value) in dict {
            if let text = value as? String {
                out[key] = QueryPredicate(legacyWireValue: text)
            } else if let object = value as? [String: Any] {
                if let equals = object["equals"] as? String { out[key] = .equals(equals) }
                else if (object["present"] as? Bool) == true { out[key] = .present }
            }
        }
        return out.isEmpty ? nil : out
    }

    static func ruleActions(from raw: [String: Any]) throws -> RuleActions {
        var actions = RuleActions()

        // The route is exactly one of block/mock/map_remote/map_local. Reject more
        // than one rather than silently picking — the AI must see the conflict.
        var routes: [Route] = []
        if (raw["block"] as? Bool) == true { routes.append(.block) }
        if let mock = raw["mock_response"] as? [String: Any] {
            let base64 = mock["body_base64"] as? String
            // Refused here, where the offending string still exists to quote: the
            // model holds decoded bytes, so an undecodable payload would otherwise
            // become a silently empty body.
            if let base64, Data(base64Encoded: base64) == nil {
                throw MCPError.invalidParams("mock_response.body_base64 is not valid base64")
            }
            routes.append(.mock(MockResponseAction.fromWire(
                statusCode: (mock["status_code"] as? Int) ?? 200,
                headers: headerPairs(mock["headers"]),
                bodyText: mock["body"] as? String,
                bodyBase64: base64,
                contentType: mock["content_type"] as? String
            )))
        }
        if let map = raw["map_remote"] as? [String: Any] {
            guard let destination = map["destination"] as? String, !destination.isEmpty else {
                throw MCPError.invalidParams("map_remote requires a non-empty `destination`")
            }
            routes.append(.mapRemote(MapRemoteAction(
                destination: destination,
                excludePattern: (map["exclude"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                keepHostHeader: (map["keep_host_header"] as? Bool) ?? false
            )))
        }
        if let map = raw["map_local"] as? [String: Any] {
            guard let path = map["path"] as? String, !path.isEmpty else {
                throw MCPError.invalidParams("map_local requires a non-empty `path`")
            }
            routes.append(.mapLocal(MapLocalAction(
                path: path,
                statusCode: (map["status_code"] as? Int) ?? 200,
                contentType: map["content_type"] as? String
            )))
        }
        guard routes.count <= 1 else {
            throw MCPError.invalidParams("set at most one of block/mock_response/map_remote/map_local")
        }
        actions.route = routes.first ?? .passthrough

        if let rewrite = raw["rewrite_request"] as? [String: Any] {
            // One body, two spellings on the wire; the boundary that can receive
            // both is where the choice is made, and a file outranks inline text.
            let body: RewriteBody?
            if let path = rewrite["body_file"] as? String, !path.isEmpty {
                body = .file(path: path)
            } else if let text = rewrite["body"] as? String {
                body = .text(text)
            } else {
                body = nil
            }
            actions.rewriteRequest = RequestRewriteAction(
                method: rewrite["method"] as? String,
                url: (rewrite["url"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                setHeaders: headerPairs(rewrite["set_headers"]),
                removeHeaders: (rewrite["remove_headers"] as? [String]) ?? [],
                body: body
            )
        }
        if let rewrite = raw["rewrite_response"] as? [String: Any] {
            actions.rewriteResponse = ResponseRewriteAction(
                statusCode: rewrite["status_code"] as? Int,
                setHeaders: headerPairs(rewrite["set_headers"]),
                removeHeaders: (rewrite["remove_headers"] as? [String]) ?? [],
                bodyText: rewrite["body"] as? String
            )
        }
        actions.requestSubstitutions = try substitutions(raw["request_substitutions"], key: "request_substitutions")
        actions.responseSubstitutions = try substitutions(raw["response_substitutions"], key: "response_substitutions")
        actions.delayMilliseconds = raw["delay_ms"] as? Int
        return actions
    }

    /// Parse substitutions strictly: a malformed item (bad `field` enum, missing
    /// `match`) is an error, not a silently-dropped row — otherwise the AI is told
    /// the rule was created while the store holds less than it sent.
    static func substitutions(_ raw: Any?, key: String) throws -> [SubstitutionRule] {
        guard let raw else { return [] }
        guard let array = raw as? [[String: Any]] else {
            throw MCPError.invalidParams("\(key) must be an array of {field, match, ...} objects")
        }
        return try array.map { item in
            guard let fieldRaw = item["field"] as? String else {
                throw MCPError.invalidParams("\(key): each item needs a `field`")
            }
            guard let kind = SubstitutionRule.Field.Kind(rawValue: fieldRaw) else {
                throw MCPError.invalidParams("\(key): invalid field \"\(fieldRaw)\" (url/header/body)")
            }
            let headerName = item["header_name"] as? String
            if headerName != nil, kind != .header {
                throw MCPError.invalidParams("\(key): header_name only applies to field \"header\"")
            }
            let field = SubstitutionRule.Field(kind: kind, headerName: headerName)
            guard let match = item["match"] as? String else {
                throw MCPError.invalidParams("\(key): each item needs a `match` string")
            }
            return SubstitutionRule(
                field: field,
                match: match,
                replacement: (item["replacement"] as? String) ?? "",
                isRegex: (item["is_regex"] as? Bool) ?? false,
                caseSensitive: (item["case_sensitive"] as? Bool) ?? false
            )
        }
    }

    static func headerPairs(_ raw: Any?) -> [HeaderPair] {
        guard let dict = raw as? [String: Any] else { return [] }
        return dict.map { HeaderPair(name: $0.key, value: String(describing: $0.value)) }
    }

    static func rule(_ rule: TrafficRule, truncateBodies: Bool) -> [String: Any] {
        MCPRender.dict(RuleRender(rule, truncateBodies: truncateBodies))
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
