import Foundation
import SharedModels

/// Dispatches MCP `tools/call` requests to the proxy engine and renders results.
/// Read tools inspect captured traffic; `replay_flow` is the write tool that
/// makes Loom "AI-operable" rather than merely AI-readable.
struct MCPToolExecutor {
    let engine: ProxyControlling
    let appVersion: String
    let protocolVersion: String

    /// JSON metadata advertised by `tools/list`.
    var toolDefinitions: [[String: Any]] {
        [
            [
                "name": "get_version",
                "description": "Get the Loom app version and MCP protocol version.",
                "inputSchema": ["type": "object", "properties": [:] as [String: Any]],
            ],
            [
                "name": "get_proxy_status",
                "description": "Get the current proxy status: running state, port, and captured flow count.",
                "inputSchema": ["type": "object", "properties": [:] as [String: Any]],
            ],
            [
                "name": "get_recent_flows",
                "description": "List recently captured HTTP flows, newest first, with method, url, status and timing.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "limit": ["type": "integer", "description": "Max flows to return (default 20)."],
                    ],
                ],
            ],
            [
                "name": "get_flow_detail",
                "description": "Get full request and response detail for one flow by id, including headers and body.",
                "inputSchema": [
                    "type": "object",
                    "properties": ["id": ["type": "string", "description": "Flow UUID."]],
                    "required": ["id"],
                ],
            ],
            [
                "name": "replay_flow",
                "description": "Re-send a captured flow with optional overrides (method, url, headers, body) and return the new flow. This is a write action.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "id": ["type": "string", "description": "Flow UUID to replay."],
                        "method": ["type": "string"],
                        "url": ["type": "string"],
                        "set_headers": [
                            "type": "object",
                            "description": "Header name/value pairs to add or overwrite.",
                        ],
                        "remove_headers": [
                            "type": "array",
                            "items": ["type": "string"],
                            "description": "Header names to remove.",
                        ],
                        "body": ["type": "string", "description": "Replacement request body (UTF-8)."],
                    ],
                    "required": ["id"],
                ],
            ],
            [
                "name": "get_certificate_status",
                "description": "Get the HTTPS-interception root CA status: whether it exists, whether it's trusted on this machine, its SHA-256 fingerprint, expiry, and exported PEM path.",
                "inputSchema": ["type": "object", "properties": [:] as [String: Any]],
            ],
            [
                "name": "export_ca_certificate",
                "description": "Write Loom's root CA certificate (PEM) to disk so it can be trusted, and return the file path. This is a write action.",
                "inputSchema": ["type": "object", "properties": [:] as [String: Any]],
            ],
            [
                "name": "get_ssl_scope",
                "description": "Get the SSL-proxying scope: whether interception is enabled and the include/exclude host globs. Hosts matching an include glob (and no exclude glob) are MITM-decrypted; everything else is blind-tunneled.",
                "inputSchema": ["type": "object", "properties": [:] as [String: Any]],
            ],
            [
                "name": "set_ssl_scope",
                "description": "Set the SSL-proxying scope. Enables/disables HTTPS interception and replaces the include/exclude host globs (e.g. \"*.example.com\"). exclude doubles as the pinned/pass-through list. This is a write action.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "enabled": ["type": "boolean", "description": "Master switch for HTTPS interception."],
                        "include": [
                            "type": "array",
                            "items": ["type": "string"],
                            "description": "Host globs to decrypt, e.g. [\"*.example.com\", \"api.test\"].",
                        ],
                        "exclude": [
                            "type": "array",
                            "items": ["type": "string"],
                            "description": "Host globs to pass through untouched (pinned hosts).",
                        ],
                    ],
                ],
            ],
            [
                "name": "export_har",
                "description": "Export captured flows to a HAR 1.2 file (readable by Chrome DevTools / Charles / Proxyman) and return the path. Optionally filter by host and cap the count. This is a write action (writes a file).",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "host": ["type": "string", "description": "Only include flows whose host contains this string."],
                        "limit": ["type": "integer", "description": "Max flows to include (default 1000, newest first)."],
                        "path": ["type": "string", "description": "Absolute output path; defaults to ~/Library/Application Support/com.loom/exports/loom-export.har."],
                    ],
                ],
            ],
            [
                "name": "list_rules",
                "description": "List all traffic rules and the master rules switch. Mock/rewrite bodies are truncated; use get_rule for the full rule.",
                "inputSchema": ["type": "object", "properties": [:] as [String: Any]],
            ],
            [
                "name": "get_rule",
                "description": "Get one traffic rule by id, with full (untruncated) bodies.",
                "inputSchema": [
                    "type": "object",
                    "properties": ["id": ["type": "string", "description": "Rule UUID."]],
                    "required": ["id"],
                ],
            ],
            [
                "name": "create_rule",
                "description": "Create a traffic rule: match requests by URL pattern (+ optional methods) and act on them — mock the response, map to another origin or a local file, rewrite request/response headers or bodies, block, or delay. Rules apply to live traffic and replays, in list order. This is a write action.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "name": ["type": "string", "description": "Short human-readable rule name (shows in flow audit trails)."],
                        "comment": ["type": "string", "description": "Optional note on why the rule exists."],
                        "group": ["type": "string", "description": "Optional group label (e.g. one group per scenario); a whole group can be toggled with set_group_enabled."],
                        "enabled": ["type": "boolean", "description": "Default true."],
                        "match": Self.matchSchema,
                        "actions": Self.actionsSchema,
                    ],
                    "required": ["name", "match", "actions"],
                ],
            ],
            [
                "name": "update_rule",
                "description": "Update a traffic rule by id. Provided fields replace the existing ones (match/actions are replaced whole, not merged). Toggle a single rule with just {id, enabled}. This is a write action.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "id": ["type": "string", "description": "Rule UUID."],
                        "name": ["type": "string"],
                        "comment": ["type": "string"],
                        "group": ["type": "string", "description": "New group label; pass \"\" to ungroup."],
                        "enabled": ["type": "boolean"],
                        "match": Self.matchSchema,
                        "actions": Self.actionsSchema,
                    ],
                    "required": ["id"],
                ],
            ],
            [
                "name": "delete_rule",
                "description": "Delete a traffic rule by id. This is a write action.",
                "inputSchema": [
                    "type": "object",
                    "properties": ["id": ["type": "string", "description": "Rule UUID."]],
                    "required": ["id"],
                ],
            ],
            [
                "name": "set_rules_enabled",
                "description": "Master switch for the rule engine. When off, no rule is applied regardless of per-rule flags. This is a write action.",
                "inputSchema": [
                    "type": "object",
                    "properties": ["enabled": ["type": "boolean"]],
                    "required": ["enabled"],
                ],
            ],
            [
                "name": "set_group_enabled",
                "description": "Enable or disable every rule in a group at once (e.g. switch debugging scenarios). This is a write action.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "group": ["type": "string", "description": "Group label as shown in list_rules."],
                        "enabled": ["type": "boolean"],
                    ],
                    "required": ["group", "enabled"],
                ],
            ],
        ]
    }

    /// Shared `match` schema for create_rule / update_rule.
    private static var matchSchema: [String: Any] {
        [
            "type": "object",
            "description": "What traffic the rule applies to, matched against the original client request.",
            "properties": [
                "url_pattern": [
                    "type": "string",
                    "description": "Matched against the full URL. Glob by default: `*` matches any characters and the pattern must cover the whole URL; without any `*` it is a prefix match (query strings still match). With is_regex it is an unanchored, case-insensitive regular expression.",
                ],
                "is_regex": ["type": "boolean", "description": "Treat url_pattern as a regular expression (default false)."],
                "methods": [
                    "type": "array",
                    "items": ["type": "string"],
                    "description": "HTTP methods to match, e.g. [\"GET\"]. Empty/omitted = all methods.",
                ],
            ],
            "required": ["url_pattern"],
        ]
    }

    /// Shared `actions` schema for create_rule / update_rule.
    private static var actionsSchema: [String: Any] {
        [
            "type": "object",
            "description": "What to do with matching traffic. Set any combination. block beats mock_response beats map_local when several short-circuits match; request rewrites compose in rule order.",
            "properties": [
                "block": ["type": "boolean", "description": "Refuse the request with 403; the upstream is never contacted."],
                "mock_response": [
                    "type": "object",
                    "description": "Short-circuit with a synthesized response; the upstream is never contacted.",
                    "properties": [
                        "status_code": ["type": "integer", "description": "Default 200."],
                        "headers": ["type": "object", "description": "Response header name/value pairs."],
                        "body": ["type": "string", "description": "UTF-8 response body (e.g. a JSON document)."],
                        "content_type": ["type": "string", "description": "Convenience Content-Type, e.g. application/json."],
                    ],
                ],
                "map_remote": [
                    "type": "object",
                    "description": "Re-send the request to a different origin, keeping path + query.",
                    "properties": [
                        "destination": ["type": "string", "description": "Origin like http://127.0.0.1:3001 (scheme + host + optional port)."],
                        "exclude": ["type": "string", "description": "URLs matching this glob/regex are left un-redirected."],
                        "keep_host_header": ["type": "boolean", "description": "Keep the original Host header instead of following the new origin."],
                    ],
                    "required": ["destination"],
                ],
                "map_local": [
                    "type": "object",
                    "description": "Serve a local file as the response; the upstream is never contacted.",
                    "properties": [
                        "path": ["type": "string", "description": "Absolute file path."],
                        "status_code": ["type": "integer", "description": "Default 200."],
                        "content_type": ["type": "string", "description": "Default: guessed from the file extension."],
                    ],
                    "required": ["path"],
                ],
                "rewrite_request": [
                    "type": "object",
                    "description": "Mutate the outgoing request before forwarding.",
                    "properties": [
                        "method": ["type": "string"],
                        "set_headers": ["type": "object", "description": "Header name/value pairs to add or overwrite."],
                        "remove_headers": ["type": "array", "items": ["type": "string"]],
                        "body": ["type": "string", "description": "Replacement UTF-8 request body."],
                    ],
                ],
                "rewrite_response": [
                    "type": "object",
                    "description": "Mutate the response (real or mocked) before it reaches the client.",
                    "properties": [
                        "status_code": ["type": "integer"],
                        "set_headers": ["type": "object", "description": "Header name/value pairs to add or overwrite."],
                        "remove_headers": ["type": "array", "items": ["type": "string"]],
                        "body": ["type": "string", "description": "Replacement UTF-8 response body."],
                    ],
                ],
                "request_substitutions": Self.substitutionsSchema(
                    "Find/replace substitutions on the outgoing request (\"modify request\"). Applied in order."),
                "response_substitutions": Self.substitutionsSchema(
                    "Find/replace substitutions on the returned response (\"modify response\"). Applied in order."),
                "delay_ms": ["type": "integer", "description": "Hold the response back this many milliseconds (crude throttle)."],
            ],
        ]
    }

    private static func substitutionsSchema(_ description: String) -> [String: Any] {
        [
            "type": "array",
            "description": description,
            "items": [
                "type": "object",
                "properties": [
                    "field": ["type": "string", "enum": ["url", "header", "body"], "description": "Which part to substitute in (url is request-side only)."],
                    "match": ["type": "string", "description": "Text or regex to find."],
                    "replacement": ["type": "string", "description": "Replacement text (regex $1 backrefs allowed)."],
                    "is_regex": ["type": "boolean", "description": "Treat match as a regular expression (default false)."],
                    "case_sensitive": ["type": "boolean", "description": "Case-sensitive match (default false)."],
                ],
                "required": ["field", "match"],
            ],
        ]
    }

    /// Returns the MCP tool-result content array (a single text block) or throws
    /// a `MCPError` describing why the call failed.
    func call(name: String, arguments: [String: Any]) async throws -> String {
        switch name {
        case "get_version":
            return prettyJSON([
                "app": "Loom",
                "appVersion": appVersion,
                "protocolVersion": protocolVersion,
            ])

        case "get_proxy_status":
            let status = await engine.status()
            return prettyJSON([
                "isRunning": status.isRunning,
                "port": status.port,
                "capturedCount": status.capturedCount,
                "isRecording": status.isRecording,
            ])

        case "get_recent_flows":
            let limit = (arguments["limit"] as? Int) ?? 20
            let flows = await engine.recentFlows(limit: limit)
            return prettyJSON(flows.map(Self.flowSummary))

        case "get_flow_detail":
            guard let idString = arguments["id"] as? String, let id = UUID(uuidString: idString) else {
                throw MCPError.invalidParams("`id` must be a flow UUID string")
            }
            guard let flow = await engine.flow(id: id) else {
                throw MCPError.invalidParams("no flow with id \(idString)")
            }
            return prettyJSON(Self.flowDetail(flow))

        case "replay_flow":
            guard let idString = arguments["id"] as? String, let id = UUID(uuidString: idString) else {
                throw MCPError.invalidParams("`id` must be a flow UUID string")
            }
            let overrides = Self.overrides(from: arguments)
            do {
                let flow = try await engine.replay(id: id, overrides: overrides)
                return prettyJSON(Self.flowDetail(flow))
            } catch let error as ProxyControlError {
                throw MCPError.internalError(String(describing: error))
            }

        case "get_certificate_status":
            return prettyJSON(Self.certificateStatus(await engine.certificateStatus()))

        case "export_ca_certificate":
            do {
                let url = try await engine.exportCACertificate()
                return prettyJSON([
                    "path": url.path,
                    "hint": "Trust it with: sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain \(url.path)",
                ])
            } catch let error as ProxyControlError {
                throw MCPError.internalError(String(describing: error))
            }

        case "get_ssl_scope":
            return prettyJSON(Self.scope(await engine.sslScope()))

        case "set_ssl_scope":
            let current = await engine.sslScope()
            let scope = SSLScope(
                enabled: (arguments["enabled"] as? Bool) ?? current.enabled,
                include: (arguments["include"] as? [String]) ?? current.include,
                exclude: (arguments["exclude"] as? [String]) ?? current.exclude
            )
            await engine.setSSLScope(scope)
            return prettyJSON(Self.scope(scope))

        case "export_har":
            let limit = (arguments["limit"] as? Int) ?? 1000
            var flows = await engine.recentFlows(limit: limit)
            if let host = (arguments["host"] as? String), !host.isEmpty {
                let needle = host.lowercased()
                flows = flows.filter { ($0.host ?? "").lowercased().contains(needle) }
            }
            let data = HARExport.encode(flows, appVersion: appVersion)
            let url: URL
            if let path = arguments["path"] as? String, !path.isEmpty {
                url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            } else {
                url = HandshakeStore.directory
                    .appendingPathComponent("exports", isDirectory: true)
                    .appendingPathComponent("loom-export.har")
            }
            do {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: url, options: .atomic)
            } catch {
                throw MCPError.internalError("could not write HAR to \(url.path): \(error.localizedDescription)")
            }
            return prettyJSON(["path": url.path, "entries": flows.count])

        case "list_rules":
            let state = await engine.rulesState()
            return prettyJSON([
                "enabled": state.enabled,
                "count": state.rules.count,
                "rules": state.rules.map { Self.rule($0, truncateBodies: true) },
            ])

        case "get_rule":
            let rule = try await existingRule(arguments)
            return prettyJSON(Self.rule(rule, truncateBodies: false))

        case "create_rule":
            guard let ruleName = arguments["name"] as? String else {
                throw MCPError.invalidParams("`name` is required")
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
                actions: Self.ruleActions(from: actionsRaw)
            )
            do {
                try await engine.addRule(rule)
            } catch let error as ProxyControlError {
                throw MCPError.invalidParams(String(describing: error))
            }
            return prettyJSON(Self.rule(rule, truncateBodies: false))

        case "update_rule":
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
                rule.actions = Self.ruleActions(from: actionsRaw)
            }
            do {
                try await engine.updateRule(rule)
            } catch let error as ProxyControlError {
                throw MCPError.invalidParams(String(describing: error))
            }
            return prettyJSON(Self.rule(rule, truncateBodies: false))

        case "delete_rule":
            let rule = try await existingRule(arguments)
            do {
                try await engine.deleteRule(id: rule.id)
            } catch let error as ProxyControlError {
                throw MCPError.invalidParams(String(describing: error))
            }
            return prettyJSON(["deleted": rule.id.uuidString, "name": rule.name])

        case "set_rules_enabled":
            guard let enabled = arguments["enabled"] as? Bool else {
                throw MCPError.invalidParams("`enabled` (boolean) is required")
            }
            await engine.setRulesEnabled(enabled)
            let state = await engine.rulesState()
            return prettyJSON(["enabled": state.enabled, "count": state.rules.count])

        case "set_group_enabled":
            guard let group = Self.groupName(arguments["group"]) else {
                throw MCPError.invalidParams("`group` (non-empty string) is required")
            }
            guard let enabled = arguments["enabled"] as? Bool else {
                throw MCPError.invalidParams("`enabled` (boolean) is required")
            }
            let members = await engine.rulesState().rules.filter { $0.group == group }
            guard !members.isEmpty else {
                throw MCPError.invalidParams("no rules in group \"\(group)\" — see list_rules")
            }
            await engine.setGroupEnabled(group: group, enabled: enabled)
            return prettyJSON(["group": group, "enabled": enabled, "affected": members.count])

        default:
            throw MCPError.methodNotFound("unknown tool: \(name)")
        }
    }

    /// Resolve the `id` argument to a stored rule or throw a structured error.
    private func existingRule(_ arguments: [String: Any]) async throws -> TrafficRule {
        guard let idString = arguments["id"] as? String, let id = UUID(uuidString: idString) else {
            throw MCPError.invalidParams("`id` must be a rule UUID string")
        }
        guard let rule = await engine.rulesState().rules.first(where: { $0.id == id }) else {
            throw MCPError.invalidParams("no rule with id \(idString)")
        }
        return rule
    }

    // MARK: - Rendering

    private static func flowSummary(_ flow: Flow) -> [String: Any] {
        var out: [String: Any] = [
            "id": flow.id.uuidString,
            "method": flow.request.method,
            "url": flow.request.url,
        ]
        if let status = flow.statusCode { out["status"] = status }
        if let ms = flow.durationMS { out["durationMS"] = ms }
        if let error = flow.error { out["error"] = error }
        if let from = flow.replayedFrom { out["replayedFrom"] = from.uuidString }
        if let applied = flow.appliedRules { out["appliedRules"] = applied }
        if let app = flow.sourceApp {
            var appOut: [String: Any] = ["name": app.name, "pid": Int(app.pid)]
            if let bundleID = app.bundleID { appOut["bundleID"] = bundleID }
            out["sourceApp"] = appOut
        }
        return out
    }

    private static func flowDetail(_ flow: Flow) -> [String: Any] {
        var out = flowSummary(flow)
        out["request"] = [
            "method": flow.request.method,
            "url": flow.request.url,
            "headers": flow.request.headers.map { ["name": $0.name, "value": $0.value] },
            "body": flow.request.body.flatMap { String(data: $0, encoding: .utf8) } ?? "",
        ]
        if let response = flow.response {
            out["response"] = [
                "status": response.statusCode,
                "headers": response.headers.map { ["name": $0.name, "value": $0.value] },
                "body": response.body.flatMap { String(data: $0, encoding: .utf8) } ?? "",
            ]
        }
        return out
    }

    private static func certificateStatus(_ status: CertificateStatus) -> [String: Any] {
        var out: [String: Any] = [
            "isGenerated": status.isGenerated,
            "isTrusted": status.isTrusted,
        ]
        if let cn = status.commonName { out["commonName"] = cn }
        if let fp = status.sha256Fingerprint { out["sha256Fingerprint"] = fp }
        if let notAfter = status.notAfter { out["notAfter"] = ISO8601DateFormatter().string(from: notAfter) }
        if let path = status.exportedPEMPath { out["exportedPEMPath"] = path }
        return out
    }

    private static func scope(_ scope: SSLScope) -> [String: Any] {
        [
            "enabled": scope.enabled,
            "include": scope.include,
            "exclude": scope.exclude,
        ]
    }

    // MARK: - Rules parsing / rendering

    /// Normalize a group argument: empty/whitespace (or non-string) means "no group".
    private static func groupName(_ raw: Any?) -> String? {
        guard let name = (raw as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !name.isEmpty else { return nil }
        return name
    }

    private static func ruleMatch(from raw: [String: Any]) -> RuleMatch? {
        guard let pattern = raw["url_pattern"] as? String else { return nil }
        return RuleMatch(
            urlPattern: pattern,
            isRegex: (raw["is_regex"] as? Bool) ?? false,
            methods: (raw["methods"] as? [String]) ?? []
        )
    }

    private static func ruleActions(from raw: [String: Any]) -> RuleActions {
        var actions = RuleActions()
        actions.block = (raw["block"] as? Bool) ?? false
        if let mock = raw["mock_response"] as? [String: Any] {
            actions.mockResponse = MockResponseAction(
                statusCode: (mock["status_code"] as? Int) ?? 200,
                headers: headerPairs(mock["headers"]),
                bodyText: mock["body"] as? String,
                contentType: mock["content_type"] as? String
            )
        }
        if let map = raw["map_remote"] as? [String: Any], let destination = map["destination"] as? String {
            actions.mapRemote = MapRemoteAction(
                destination: destination,
                excludePattern: (map["exclude"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                keepHostHeader: (map["keep_host_header"] as? Bool) ?? false
            )
        }
        if let map = raw["map_local"] as? [String: Any], let path = map["path"] as? String {
            actions.mapLocal = MapLocalAction(
                path: path,
                statusCode: (map["status_code"] as? Int) ?? 200,
                contentType: map["content_type"] as? String
            )
        }
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
        actions.requestSubstitutions = substitutions(raw["request_substitutions"])
        actions.responseSubstitutions = substitutions(raw["response_substitutions"])
        actions.delayMilliseconds = raw["delay_ms"] as? Int
        return actions
    }

    private static func substitutions(_ raw: Any?) -> [SubstitutionRule] {
        guard let array = raw as? [[String: Any]] else { return [] }
        return array.compactMap { item in
            guard let fieldRaw = item["field"] as? String,
                  let field = SubstitutionRule.Field(rawValue: fieldRaw),
                  let match = item["match"] as? String else { return nil }
            return SubstitutionRule(
                field: field,
                match: match,
                replacement: (item["replacement"] as? String) ?? "",
                isRegex: (item["is_regex"] as? Bool) ?? false,
                caseSensitive: (item["case_sensitive"] as? Bool) ?? false
            )
        }
    }

    private static func headerPairs(_ raw: Any?) -> [HeaderPair] {
        guard let dict = raw as? [String: Any] else { return [] }
        return dict.map { HeaderPair(name: $0.key, value: String(describing: $0.value)) }
    }

    private static func rule(_ rule: TrafficRule, truncateBodies: Bool) -> [String: Any] {
        var out: [String: Any] = [
            "id": rule.id.uuidString,
            "name": rule.name,
            "enabled": rule.isEnabled,
            "match": {
                var match: [String: Any] = ["urlPattern": rule.match.urlPattern]
                if rule.match.isRegex { match["isRegex"] = true }
                if !rule.match.methods.isEmpty { match["methods"] = rule.match.methods }
                return match
            }(),
            "createdAt": ISO8601DateFormatter().string(from: rule.createdAt),
        ]
        if let comment = rule.comment { out["comment"] = comment }
        if let group = rule.group { out["group"] = group }

        var actions: [String: Any] = [:]
        let a = rule.actions
        if a.block { actions["block"] = true }
        if let mock = a.mockResponse {
            var mockOut: [String: Any] = ["statusCode": mock.statusCode]
            if !mock.headers.isEmpty { mockOut["headers"] = headerDict(mock.headers) }
            if let contentType = mock.contentType { mockOut["contentType"] = contentType }
            addBody(mock.bodyText, to: &mockOut, truncate: truncateBodies)
            actions["mockResponse"] = mockOut
        }
        if let map = a.mapRemote {
            var mapOut: [String: Any] = ["destination": map.destination]
            if let exclude = map.excludePattern { mapOut["exclude"] = exclude }
            if map.keepHostHeader { mapOut["keepHostHeader"] = true }
            actions["mapRemote"] = mapOut
        }
        if let map = a.mapLocal {
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

    private static func substitutionDict(_ sub: SubstitutionRule) -> [String: Any] {
        var out: [String: Any] = ["field": sub.field.rawValue, "match": sub.match, "replacement": sub.replacement]
        if sub.isRegex { out["isRegex"] = true }
        if sub.caseSensitive { out["caseSensitive"] = true }
        return out
    }

    private static func headerDict(_ headers: [HeaderPair]) -> [String: String] {
        Dictionary(headers.map { ($0.name, $0.value) }, uniquingKeysWith: { _, last in last })
    }

    /// Keep `list_rules` light: long bodies are cut to a preview + total length so
    /// a rule list with big JSON mocks doesn't flood the agent's context.
    private static func addBody(_ text: String?, to out: inout [String: Any], truncate: Bool) {
        guard let text else { return }
        let limit = 200
        if truncate, text.count > limit {
            out["body"] = String(text.prefix(limit))
            out["bodyLength"] = text.count
            out["bodyTruncated"] = true
        } else {
            out["body"] = text
        }
    }

    private static func overrides(from arguments: [String: Any]) -> ReplayOverrides {
        var setHeaders: [HeaderPair]?
        if let raw = arguments["set_headers"] as? [String: Any] {
            setHeaders = raw.map { HeaderPair(name: $0.key, value: String(describing: $0.value)) }
        }
        let removeHeaders = arguments["remove_headers"] as? [String]
        let bodyString = arguments["body"] as? String
        return ReplayOverrides(
            method: arguments["method"] as? String,
            url: arguments["url"] as? String,
            setHeaders: setHeaders,
            removeHeaders: removeHeaders,
            body: bodyString.map { Data($0.utf8) }
        )
    }

    private func prettyJSON(_ value: Any) -> String {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]),
              let string = String(data: data, encoding: .utf8)
        else {
            return String(describing: value)
        }
        return string
    }
}
