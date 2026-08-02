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
        return prettyJSON([
            "enabled": state.enabled,
            "count": state.rules.count,
            "rules": state.rules.map { Self.rule($0, truncateBodies: true) },
        ])
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
        return prettyJSON(Self.rule(rule, truncateBodies: false))
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
        return prettyJSON(Self.rule(rule, truncateBodies: false))
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
        return prettyJSON(["group": group, "enabled": enabled, "affected": members.count])
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

    static func ruleMatch(from raw: [String: Any]) -> RuleMatch? {
        guard let pattern = raw["url_pattern"] as? String else { return nil }
        return RuleMatch(
            urlPattern: pattern,
            isRegex: (raw["is_regex"] as? Bool) ?? false,
            methods: (raw["methods"] as? [String]) ?? [],
            isExact: (raw["is_exact"] as? Bool) ?? false,
            hostPattern: (raw["host_pattern"] as? String).flatMap { $0.isEmpty ? nil : $0 },
            query: (raw["query"] as? [String: String]).flatMap { $0.isEmpty ? nil : $0 },
            sourceApp: (raw["source_app"] as? String).flatMap { $0.isEmpty ? nil : $0 },
            deviceIP: (raw["device_ip"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        )
    }

    static func ruleActions(from raw: [String: Any]) throws -> RuleActions {
        var actions = RuleActions()

        // The route is exactly one of block/mock/map_remote/map_local. Reject more
        // than one rather than silently picking — the AI must see the conflict.
        var routes: [Route] = []
        if (raw["block"] as? Bool) == true { routes.append(.block) }
        if let mock = raw["mock_response"] as? [String: Any] {
            routes.append(.mock(MockResponseAction(
                statusCode: (mock["status_code"] as? Int) ?? 200,
                headers: headerPairs(mock["headers"]),
                bodyText: mock["body"] as? String,
                bodyBase64: mock["body_base64"] as? String,
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
            actions.rewriteRequest = RequestRewriteAction(
                method: rewrite["method"] as? String,
                setHeaders: headerPairs(rewrite["set_headers"]),
                removeHeaders: (rewrite["remove_headers"] as? [String]) ?? [],
                bodyText: rewrite["body"] as? String
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
            guard let field = SubstitutionRule.Field(rawValue: fieldRaw) else {
                throw MCPError.invalidParams("\(key): invalid field \"\(fieldRaw)\" (url/header/body)")
            }
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
        var out: [String: Any] = [
            "id": rule.id.uuidString,
            "name": rule.name,
            "enabled": rule.isEnabled,
            "match": matchDict(rule.match),
            "createdAt": Self.iso8601.string(from: rule.createdAt),
        ]
        if let comment = rule.comment { out["comment"] = comment }
        if let group = rule.group { out["group"] = group }

        var actions: [String: Any] = [:]
        let a = rule.actions
        switch a.route {
        case .passthrough:
            break
        case .block:
            actions["block"] = true
        case let .mock(mock):
            var mockOut: [String: Any] = ["statusCode": mock.statusCode]
            if !mock.headers.isEmpty { mockOut["headers"] = headerDict(mock.headers) }
            if let contentType = mock.contentType { mockOut["contentType"] = contentType }
            addBody(mock.bodyText, to: &mockOut, truncate: truncateBodies)
            if let base64 = mock.bodyBase64 {
                mockOut["bodyBase64"] = truncateBodies && base64.count > 256
                    ? String(base64.prefix(256)) + "…(\(base64.count) base64 chars)"
                    : base64
            }
            actions["mockResponse"] = mockOut
        case let .mapRemote(map):
            var mapOut: [String: Any] = ["destination": map.destination]
            if let exclude = map.excludePattern { mapOut["exclude"] = exclude }
            if map.keepHostHeader { mapOut["keepHostHeader"] = true }
            actions["mapRemote"] = mapOut
        case let .mapLocal(map):
            var mapOut: [String: Any] = ["path": map.path, "statusCode": map.statusCode]
            if let contentType = map.contentType { mapOut["contentType"] = contentType }
            actions["mapLocal"] = mapOut
        }
        if let rewrite = a.rewriteRequest, !rewrite.isEmpty {
            var rw: [String: Any] = [:]
            if let method = rewrite.method { rw["method"] = method }
            if !rewrite.setHeaders.isEmpty { rw["setHeaders"] = headerDict(rewrite.setHeaders) }
            if !rewrite.removeHeaders.isEmpty { rw["removeHeaders"] = rewrite.removeHeaders }
            addBody(rewrite.bodyText, to: &rw, truncate: truncateBodies)
            actions["rewriteRequest"] = rw
        }
        if let rewrite = a.rewriteResponse, !rewrite.isEmpty {
            var rw: [String: Any] = [:]
            if let status = rewrite.statusCode { rw["statusCode"] = status }
            if !rewrite.setHeaders.isEmpty { rw["setHeaders"] = headerDict(rewrite.setHeaders) }
            if !rewrite.removeHeaders.isEmpty { rw["removeHeaders"] = rewrite.removeHeaders }
            addBody(rewrite.bodyText, to: &rw, truncate: truncateBodies)
            actions["rewriteResponse"] = rw
        }
        if !a.activeRequestSubstitutions.isEmpty {
            actions["requestSubstitutions"] = a.activeRequestSubstitutions.map(substitutionDict)
        }
        if !a.activeResponseSubstitutions.isEmpty {
            actions["responseSubstitutions"] = a.activeResponseSubstitutions.map(substitutionDict)
        }
        if let delay = a.delayMilliseconds { actions["delayMs"] = delay }
        out["actions"] = actions
        return out
    }

    static func substitutionDict(_ sub: SubstitutionRule) -> [String: Any] {
        var out: [String: Any] = ["field": sub.field.rawValue, "match": sub.match, "replacement": sub.replacement]
        if sub.isRegex { out["isRegex"] = true }
        if sub.caseSensitive { out["caseSensitive"] = true }
        return out
    }

    /// The one rendering of a `RuleMatch`, shared by `list_rules` and by the
    /// breakpoint tools — the two surfaces that show an agent what a match says.
    /// It was written twice, identically, and a predicate added to only one copy
    /// would have meant a rule and a breakpoint scoped the same way reading back
    /// differently. `RuleMatch` is already parsed once (`ruleMatch(from:)`) and
    /// advertised once (`matchSchema`); this closes the third side.
    static func matchDict(_ match: RuleMatch) -> [String: Any] {
        var out: [String: Any] = ["urlPattern": match.urlPattern]
        if match.isRegex { out["isRegex"] = true }
        if match.isExact { out["isExact"] = true }
        if let hostPattern = match.hostPattern, !hostPattern.isEmpty { out["hostPattern"] = hostPattern }
        if let query = match.query, !query.isEmpty { out["query"] = query }
        if let sourceApp = match.sourceApp, !sourceApp.isEmpty { out["sourceApp"] = sourceApp }
        if let deviceIP = match.deviceIP, !deviceIP.isEmpty { out["deviceIP"] = deviceIP }
        if !match.methods.isEmpty { out["methods"] = match.methods }
        return out
    }
}
