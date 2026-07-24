import Foundation
import LoomSharedModels

/// Dispatches MCP `tools/call` requests to the proxy engine and renders results.
/// Read tools inspect captured traffic; `replay_flow` is the write tool that
/// makes Loom "AI-operable" rather than merely AI-readable.
struct MCPToolExecutor {
    let engine: ProxyControlling
    let appVersion: String
    let protocolVersion: String

    /// `ISO8601DateFormatter` is expensive to allocate; render every timestamp
    /// through one shared instance.
    private static let iso8601 = ISO8601DateFormatter()

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
                "name": "list_devices",
                "description": "List devices that have sent traffic through the proxy — this Mac plus any LAN devices (e.g. phones), each with detected platform/client (from User-Agent), flow count, and last-seen time.",
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
                "name": "get_audit_log",
                "description": "List recent write actions taken through Loom (replay, rules, breakpoints, ssl-scope), newest first, each with the tool name, arguments, outcome and timestamp. Read tools are never logged. Use this to review what write actions have been taken this or a prior session.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "limit": ["type": "integer", "description": "Max entries to return (default 50)."],
                    ],
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
                        "clear_body": ["type": "boolean", "description": "Send an empty request body (ignored if `body` is set)."],
                    ],
                    "required": ["id"],
                ],
            ],
            [
                "name": "diff_flows",
                "description": "Diff two captured flows and report exactly what differs: request method/url, request+response headers (added/removed/changed), status code, and a line-level body diff for text payloads. Pass `base` alone to diff a replayed flow against the flow it was replayed from. This closes the capture → modify → replay → diff loop.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "base": ["type": "string", "description": "Baseline flow UUID. If `compared` is omitted, this must be a replayed flow and it is diffed against its original (replayedFrom)."],
                        "compared": ["type": "string", "description": "The changed flow UUID to compare against `base`. Optional when `base` is a replay."],
                    ],
                    "required": ["base"],
                ],
            ],
            [
                "name": "arm_breakpoint",
                "description": "Arm a breakpoint: matching traffic is HELD mid-flight so you can inspect and edit it before it continues. Match by URL pattern (+ optional methods/host/query), same as a rule. Pause the request (before it's forwarded upstream), the response (before it reaches the client), or both. Held exchanges surface in list_pending; release them with resume. This is a write action.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "match": Self.matchSchema,
                        "on_request": ["type": "boolean", "description": "Pause the request before forwarding upstream (default true)."],
                        "on_response": ["type": "boolean", "description": "Pause the response before it reaches the client (default false)."],
                        "comment": ["type": "string", "description": "Optional note on why the breakpoint exists."],
                    ],
                    "required": ["match"],
                ],
            ],
            [
                "name": "disarm_breakpoint",
                "description": "Remove an armed breakpoint by id. Exchanges it is already holding still need a resume. This is a write action.",
                "inputSchema": [
                    "type": "object",
                    "properties": ["id": ["type": "string", "description": "Breakpoint UUID (from arm_breakpoint / list_pending)."]],
                    "required": ["id"],
                ],
            ],
            [
                "name": "list_pending",
                "description": "List currently armed breakpoints and every exchange held right now awaiting a resume decision. Each pending item carries its id (pass to resume), phase (request/response), full request, and — for a response pause — the response the client would receive. Poll this to discover held traffic (MCP has no server push).",
                "inputSchema": ["type": "object", "properties": [:] as [String: Any]],
            ],
            [
                "name": "resume",
                "description": "Release a held exchange by its pending id. Continue it (optionally editing method/url/status/headers/body first) or `abort` to fail it with a 502. Request-phase edits honor method/url; response-phase edits honor status_code; both honor header + body edits. This is a write action.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "pending_id": ["type": "string", "description": "The held exchange's id from list_pending."],
                        "abort": ["type": "boolean", "description": "Fail the exchange with a 502 instead of continuing (default false)."],
                        "method": ["type": "string", "description": "Request-phase only: replace the HTTP method."],
                        "url": ["type": "string", "description": "Request-phase only: replace the full URL."],
                        "status_code": ["type": "integer", "description": "Response-phase only: replace the status code."],
                        "set_headers": ["type": "object", "description": "Header name/value pairs to add or overwrite."],
                        "remove_headers": ["type": "array", "items": ["type": "string"], "description": "Header names to remove."],
                        "body": ["type": "string", "description": "Replacement body (UTF-8)."],
                        "clear_body": ["type": "boolean", "description": "Send an empty body (ignored if `body` is set)."],
                    ],
                    "required": ["pending_id"],
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
                        "filename": ["type": "string", "description": "Output file name (basename only; a .har suffix is added if missing). Written under ~/Library/Application Support/com.loom/exports/. Defaults to loom-export.har."],
                    ],
                ],
            ],
            [
                "name": "list_rules",
                "description": "List traffic rules and the master rules switch. Without arguments, returns all rules with mock/rewrite bodies truncated. Pass `id` to return that single rule with full (untruncated) bodies.",
                "inputSchema": [
                    "type": "object",
                    "properties": ["id": ["type": "string", "description": "Optional rule UUID — return just this rule, with full bodies."]],
                ],
            ],
            [
                "name": "set_rule",
                "description": "Create or update a traffic rule (upsert). Omit `id` to create; pass `id` to update an existing rule. A rule matches requests by URL pattern (+ optional methods) and acts on them — mock the response, map to another origin or a local file, rewrite request/response headers or bodies, block, or delay. On update, provided fields replace the existing ones (match/actions are replaced whole, not merged); toggle a single rule with just {id, enabled}. Rules apply to live traffic and replays, in list order. This is a write action.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "id": ["type": "string", "description": "Rule UUID to update. Omit to create a new rule."],
                        "name": ["type": "string", "description": "Short human-readable rule name (shows in flow audit trails). Required when creating."],
                        "comment": ["type": "string", "description": "Optional note on why the rule exists."],
                        "group": ["type": "string", "description": "Optional group label (e.g. one group per scenario); a whole group can be toggled with set_group_enabled. On update, pass \"\" to ungroup."],
                        "enabled": ["type": "boolean", "description": "Default true on create."],
                        "match": Self.matchSchema,
                        "actions": Self.actionsSchema,
                    ],
                    "required": [] as [String],
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
                "is_exact": ["type": "boolean", "description": "Require url_pattern to equal the full URL exactly, instead of the default prefix/glob match (ignored when is_regex). Default false."],
                "host_pattern": ["type": "string", "description": "Optional host glob (e.g. *.example.com) matched against the URL host; combines with url_pattern."],
                "query": ["type": "object", "description": "Optional query predicates: each key must be present and equal its value, or \"*\" to require the key with any value. Order-independent."],
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
                        "body_base64": ["type": "string", "description": "Base64-encoded response body for binary payloads (images, protobuf, gzip). Takes precedence over body."],
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
    /// Name → handler registry. Paired with the same-named entries in
    /// `toolDefinitions`; `MCPServerTests` asserts the two never drift (every
    /// advertised tool has a handler). Dispatch is a lookup, not a growing switch.
    static let handlers: [String: (MCPToolExecutor, [String: Any]) async throws -> String] = [
        "get_version": { ex, args in try await ex.handleGetVersion(args) },
        "get_proxy_status": { ex, args in try await ex.handleGetProxyStatus(args) },
        "list_devices": { ex, args in try await ex.handleListDevices(args) },
        "get_recent_flows": { ex, args in try await ex.handleGetRecentFlows(args) },
        "get_flow_detail": { ex, args in try await ex.handleGetFlowDetail(args) },
        "get_audit_log": { ex, args in try await ex.handleGetAuditLog(args) },
        "diff_flows": { ex, args in try await ex.handleDiffFlows(args) },
        "arm_breakpoint": { ex, args in try await ex.handleArmBreakpoint(args) },
        "disarm_breakpoint": { ex, args in try await ex.handleDisarmBreakpoint(args) },
        "list_pending": { ex, args in try await ex.handleListPending(args) },
        "resume": { ex, args in try await ex.handleResume(args) },
        "replay_flow": { ex, args in try await ex.handleReplayFlow(args) },
        "get_certificate_status": { ex, args in try await ex.handleGetCertificateStatus(args) },
        "export_ca_certificate": { ex, args in try await ex.handleExportCACertificate(args) },
        "get_ssl_scope": { ex, args in try await ex.handleGetSSLScope(args) },
        "set_ssl_scope": { ex, args in try await ex.handleSetSSLScope(args) },
        "export_har": { ex, args in try await ex.handleExportHAR(args) },
        "list_rules": { ex, args in try await ex.handleListRules(args) },
        "set_rule": { ex, args in try await ex.handleSetRule(args) },
        "delete_rule": { ex, args in try await ex.handleDeleteRule(args) },
        "set_rules_enabled": { ex, args in try await ex.handleSetRulesEnabled(args) },
        "set_group_enabled": { ex, args in try await ex.handleSetGroupEnabled(args) },
    ]

    /// Tools that touch real traffic — every one is audited (§ `call`). Kept as an
    /// explicit set rather than string-matching the "This is a write action."
    /// description marker, so a typo in a description can't silently stop auditing
    /// a write. `MCPServerTests` asserts this set matches the marked definitions.
    static let writeTools: Set<String> = [
        "replay_flow",
        "arm_breakpoint",
        "disarm_breakpoint",
        "resume",
        "export_ca_certificate",
        "set_ssl_scope",
        "export_har",
        "set_rule",
        "delete_rule",
        "set_rules_enabled",
        "set_group_enabled",
    ]

    func call(name: String, arguments: [String: Any]) async throws -> String {
        guard let handler = Self.handlers[name] else {
            throw MCPError.methodNotFound("unknown tool: \(name)")
        }
        // Read tools run straight through. Write tools are the whole reason Loom
        // exists — record each in the audit trail (success or failure) so the
        // supervising human can see what the agent did to real traffic.
        guard Self.writeTools.contains(name) else {
            return try await handler(self, arguments)
        }
        let renderedArgs = AuditEntry.truncate(Self.auditArguments(arguments))
        do {
            let result = try await handler(self, arguments)
            await engine.recordAudit(AuditEntry(
                tool: name, succeeded: true,
                arguments: renderedArgs, detail: AuditEntry.truncate(result)
            ))
            return result
        } catch {
            let message: String
            switch error {
            case let failure as MCPToolFailure: message = failure.message
            case let mcp as MCPError: message = mcp.message
            default: message = error.localizedDescription
            }
            await engine.recordAudit(AuditEntry(
                tool: name, succeeded: false,
                arguments: renderedArgs, detail: AuditEntry.truncate(message)
            ))
            throw error
        }
    }

    /// Render a tool's arguments as compact JSON for the audit trail. Falls back
    /// to `String(describing:)` for the rare non-JSON value. Truncation is applied
    /// by the caller (whole-string, so we don't split a key from its value).
    private static func auditArguments(_ arguments: [String: Any]) -> String {
        guard !arguments.isEmpty else { return "{}" }
        guard JSONSerialization.isValidJSONObject(arguments),
              let data = try? JSONSerialization.data(withJSONObject: arguments, options: [.sortedKeys]),
              let string = String(data: data, encoding: .utf8)
        else { return String(describing: arguments) }
        return string
    }

    // MARK: - Handlers (one per tool)

    private func handleGetVersion(_ arguments: [String: Any]) async throws -> String {
        prettyJSON([
            "app": "Loom",
            "appVersion": appVersion,
            "protocolVersion": protocolVersion,
        ])
    }

    private func handleGetProxyStatus(_ arguments: [String: Any]) async throws -> String {
        let status = await engine.status()
        return prettyJSON([
            "isRunning": status.isRunning,
            "port": status.port,
            "capturedCount": status.capturedCount,
            "isRecording": status.isRecording,
        ])
    }

    private func handleListDevices(_ arguments: [String: Any]) async throws -> String {
        let devices = await engine.connectedDevices()
        return prettyJSON(devices.map(Self.deviceSummary))
    }

    private func handleGetRecentFlows(_ arguments: [String: Any]) async throws -> String {
        let limit = (arguments["limit"] as? Int) ?? 20
        let flows = await engine.recentFlows(limit: limit)
        return prettyJSON(flows.map(Self.flowSummary))
    }

    private func handleGetFlowDetail(_ arguments: [String: Any]) async throws -> String {
        guard let idString = arguments["id"] as? String, let id = UUID(uuidString: idString) else {
            throw MCPError.invalidParams("`id` must be a flow UUID string")
        }
        guard let flow = await engine.flow(id: id) else {
            throw MCPToolFailure("no flow with id \(idString)")
        }
        return prettyJSON(Self.flowDetail(flow))
    }

    private func handleGetAuditLog(_ arguments: [String: Any]) async throws -> String {
        let limit = (arguments["limit"] as? Int) ?? 50
        let entries = await engine.recentAuditEntries(limit: limit)
        return prettyJSON(entries.map(Self.auditSummary))
    }

    private func handleDiffFlows(_ arguments: [String: Any]) async throws -> String {
        guard let baseString = arguments["base"] as? String, let baseID = UUID(uuidString: baseString) else {
            throw MCPError.invalidParams("`base` must be a flow UUID string")
        }
        guard let baseFlow = await engine.flow(id: baseID) else {
            throw MCPToolFailure("no flow with id \(baseString)")
        }

        // Resolve the two sides. Explicit `compared` wins; otherwise diff a replay
        // against the flow it was replayed from (base = original, compared = replay),
        // which is the natural one-argument "how did my replay change things" call.
        let base: Flow
        let compared: Flow
        if let comparedString = arguments["compared"] as? String {
            guard let comparedID = UUID(uuidString: comparedString) else {
                throw MCPError.invalidParams("`compared` must be a flow UUID string")
            }
            guard let comparedFlow = await engine.flow(id: comparedID) else {
                throw MCPToolFailure("no flow with id \(comparedString)")
            }
            base = baseFlow
            compared = comparedFlow
        } else {
            guard let originalID = baseFlow.replayedFrom else {
                throw MCPToolFailure("flow \(baseString) was not replayed from another flow — pass `compared` explicitly")
            }
            guard let original = await engine.flow(id: originalID) else {
                throw MCPToolFailure("original flow \(originalID.uuidString) (replayedFrom) is no longer in the store — pass `compared` explicitly")
            }
            base = original
            compared = baseFlow
        }

        return prettyJSON(FlowDiff.diff(base: base, compared: compared))
    }

    // MARK: Breakpoints

    private func handleArmBreakpoint(_ arguments: [String: Any]) async throws -> String {
        guard let matchRaw = arguments["match"] as? [String: Any],
              let match = Self.ruleMatch(from: matchRaw) else {
            throw MCPError.invalidParams("`match` with `url_pattern` is required")
        }
        let breakpoint = Breakpoint(
            match: match,
            onRequest: (arguments["on_request"] as? Bool) ?? true,
            onResponse: (arguments["on_response"] as? Bool) ?? false,
            comment: arguments["comment"] as? String
        )
        do {
            try await engine.armBreakpoint(breakpoint)
        } catch let error as ProxyControlError {
            throw MCPToolFailure(error.message)
        }
        return prettyJSON(Self.breakpoint(breakpoint))
    }

    private func handleDisarmBreakpoint(_ arguments: [String: Any]) async throws -> String {
        guard let idString = arguments["id"] as? String, let id = UUID(uuidString: idString) else {
            throw MCPError.invalidParams("`id` must be a breakpoint UUID string")
        }
        do {
            try await engine.disarmBreakpoint(id: id)
        } catch let error as ProxyControlError {
            throw MCPToolFailure(error.message)
        }
        return prettyJSON(["disarmed": idString])
    }

    private func handleListPending(_ arguments: [String: Any]) async throws -> String {
        let armed = await engine.armedBreakpoints()
        let pending = await engine.pendingBreakpoints()
        return prettyJSON([
            "armed": armed.map(Self.breakpoint),
            "pending": pending.map(Self.pendingBreakpoint),
        ])
    }

    private func handleResume(_ arguments: [String: Any]) async throws -> String {
        guard let idString = arguments["pending_id"] as? String, let id = UUID(uuidString: idString) else {
            throw MCPError.invalidParams("`pending_id` must be a held-breakpoint UUID string")
        }
        let abort = (arguments["abort"] as? Bool) ?? false
        var setHeaders: [HeaderPair]?
        if let raw = arguments["set_headers"] as? [String: Any] {
            setHeaders = raw.map { HeaderPair(name: $0.key, value: String(describing: $0.value)) }
        }
        let body: BodyOverride
        if let bodyString = arguments["body"] as? String {
            body = .replace(Data(bodyString.utf8))
        } else if (arguments["clear_body"] as? Bool) == true {
            body = .clear
        } else {
            body = .keep
        }
        let edit = BreakpointEdit(
            method: arguments["method"] as? String,
            url: arguments["url"] as? String,
            statusCode: arguments["status_code"] as? Int,
            setHeaders: setHeaders,
            removeHeaders: arguments["remove_headers"] as? [String],
            body: body
        )
        do {
            try await engine.resumeBreakpoint(pendingID: id, abort: abort, edit: edit)
        } catch let error as ProxyControlError {
            throw MCPToolFailure(error.message)
        }
        return prettyJSON(["resumed": idString, "aborted": abort])
    }

    private func handleReplayFlow(_ arguments: [String: Any]) async throws -> String {
        guard let idString = arguments["id"] as? String, let id = UUID(uuidString: idString) else {
            throw MCPError.invalidParams("`id` must be a flow UUID string")
        }
        let overrides = Self.overrides(from: arguments)
        do {
            let flow = try await engine.replay(id: id, overrides: overrides)
            return prettyJSON(Self.flowDetail(flow))
        } catch let error as ProxyControlError {
            throw MCPToolFailure(error.message)
        }
    }

    private func handleGetCertificateStatus(_ arguments: [String: Any]) async throws -> String {
        prettyJSON(Self.certificateStatus(await engine.certificateStatus()))
    }

    private func handleExportCACertificate(_ arguments: [String: Any]) async throws -> String {
        do {
            let url = try await engine.exportCACertificate()
            return prettyJSON([
                "path": url.path,
                "hint": "Trust it with: sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain \(url.path)",
            ])
        } catch let error as ProxyControlError {
            throw MCPToolFailure(error.message)
        }
    }

    private func handleGetSSLScope(_ arguments: [String: Any]) async throws -> String {
        prettyJSON(Self.scope(await engine.sslScope()))
    }

    private func handleSetSSLScope(_ arguments: [String: Any]) async throws -> String {
        let current = await engine.sslScope()
        let scope = SSLScope(
            enabled: (arguments["enabled"] as? Bool) ?? current.enabled,
            include: (arguments["include"] as? [String]) ?? current.include,
            exclude: (arguments["exclude"] as? [String]) ?? current.exclude
        )
        await engine.setSSLScope(scope)
        return prettyJSON(Self.scope(scope))
    }

    private func handleExportHAR(_ arguments: [String: Any]) async throws -> String {
        let limit = (arguments["limit"] as? Int) ?? 1000
        // HAR needs full request/response bodies, so hydrate (bodies live in
        // separate storage now); the list/summary tools stay on the body-free path.
        var flows = await engine.recentFlowsForExport(limit: limit)
        if let host = (arguments["host"] as? String), !host.isEmpty {
            let needle = host.lowercased()
            flows = flows.filter { ($0.host ?? "").lowercased().contains(needle) }
        }
        let data = HARExport.encode(flows, appVersion: appVersion)
        // Confine exports to the exports/ directory and take only a basename,
        // so the AI can't overwrite arbitrary user files (~/.zshrc, plists) via
        // a path argument. Any directory component in `filename` is stripped.
        let exportsDir = HandshakeStore.directory.appendingPathComponent("exports", isDirectory: true)
        let filename: String
        if let raw = arguments["filename"] as? String, !raw.isEmpty {
            let base = (raw as NSString).lastPathComponent
            guard !base.isEmpty, base != ".", base != "..", !base.hasPrefix(".") else {
                throw MCPError.invalidParams("invalid filename: \(raw)")
            }
            filename = base.hasSuffix(".har") ? base : base + ".har"
        } else {
            filename = "loom-export.har"
        }
        let url = exportsDir.appendingPathComponent(filename)
        do {
            try FileManager.default.createDirectory(at: exportsDir, withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        } catch {
            throw MCPToolFailure("could not write HAR to \(url.path): \(error.localizedDescription)")
        }
        return prettyJSON(["path": url.path, "entries": flows.count])
    }

    /// `list_rules`: all rules (bodies truncated), or — with `id` — one rule with
    /// full bodies. Absorbs the former `get_rule`.
    private func handleListRules(_ arguments: [String: Any]) async throws -> String {
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
    private func handleSetRule(_ arguments: [String: Any]) async throws -> String {
        arguments["id"] == nil
            ? try await createRule(arguments)
            : try await updateRule(arguments)
    }

    private func createRule(_ arguments: [String: Any]) async throws -> String {
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

    private func updateRule(_ arguments: [String: Any]) async throws -> String {
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

    private func handleDeleteRule(_ arguments: [String: Any]) async throws -> String {
        let rule = try await existingRule(arguments)
        do {
            try await engine.deleteRule(id: rule.id)
        } catch let error as ProxyControlError {
            throw MCPToolFailure(error.message)
        }
        return prettyJSON(["deleted": rule.id.uuidString, "name": rule.name])
    }

    private func handleSetRulesEnabled(_ arguments: [String: Any]) async throws -> String {
        guard let enabled = arguments["enabled"] as? Bool else {
            throw MCPError.invalidParams("`enabled` (boolean) is required")
        }
        await engine.setRulesEnabled(enabled)
        let state = await engine.rulesState()
        return prettyJSON(["enabled": state.enabled, "count": state.rules.count])
    }

    private func handleSetGroupEnabled(_ arguments: [String: Any]) async throws -> String {
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
    private func existingRule(_ arguments: [String: Any]) async throws -> TrafficRule {
        guard let idString = arguments["id"] as? String, let id = UUID(uuidString: idString) else {
            throw MCPError.invalidParams("`id` must be a rule UUID string")
        }
        guard let rule = await engine.rulesState().rules.first(where: { $0.id == id }) else {
            throw MCPToolFailure("no rule with id \(idString)")
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
        if let applied = flow.appliedRules { out["appliedRules"] = applied.map(\.name) }
        if let messages = flow.webSocketMessages {
            out["webSocket"] = true
            out["wsMessageCount"] = messages.count
        }
        if let app = flow.sourceApp {
            var appOut: [String: Any] = ["name": app.name, "pid": Int(app.pid)]
            if let bundleID = app.bundleID { appOut["bundleID"] = bundleID }
            out["sourceApp"] = appOut
        }
        if let device = flow.sourceDevice {
            var deviceOut: [String: Any] = ["ip": device.ip, "kind": device.kind.rawValue]
            if let platform = device.platform { deviceOut["platform"] = platform }
            if let client = device.client { deviceOut["client"] = client }
            out["sourceDevice"] = deviceOut
        }
        return out
    }

    /// One entry for `get_audit_log`. Timestamp as ISO-8601 so the model can order
    /// them; `arguments` is already-truncated compact JSON (a string, not re-parsed).
    private static func auditSummary(_ entry: AuditEntry) -> [String: Any] {
        [
            "id": entry.id.uuidString,
            "timestamp": iso8601.string(from: entry.timestamp),
            "tool": entry.tool,
            "source": entry.source.rawValue,
            "succeeded": entry.succeeded,
            "arguments": entry.arguments,
            "detail": entry.detail,
        ]
    }

    /// One entry for `list_devices`. Dates as ISO-8601 so the model can order them.
    private static func deviceSummary(_ summary: DeviceSummary) -> [String: Any] {
        let device = summary.device
        var out: [String: Any] = [
            "ip": device.ip,
            "kind": device.kind.rawValue,
            "displayName": device.displayName,
            "flowCount": summary.flowCount,
            "lastActive": ISO8601DateFormatter().string(from: summary.lastActive),
        ]
        if let platform = device.platform { out["platform"] = platform }
        if let client = device.client { out["client"] = client }
        if let type = device.typeSummary { out["type"] = type }
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
            var responseOut: [String: Any] = [
                "status": response.statusCode,
                "headers": response.headers.map { ["name": $0.name, "value": $0.value] },
                "body": response.body.flatMap { String(data: $0, encoding: .utf8) } ?? "",
            ]
            if let version = response.httpVersion { responseOut["httpVersion"] = version }
            out["response"] = responseOut
        }
        if let graphQL = GraphQLParser.parse(flow.request) {
            var gql: [String: Any] = ["kind": graphQL.kind.rawValue, "query": graphQL.query]
            if let name = graphQL.operationName { gql["operationName"] = name }
            if let variables = graphQL.variablesJSON { gql["variables"] = variables }
            out["graphQL"] = gql
        }
        if let messages = flow.webSocketMessages {
            out["webSocket"] = [
                "messageCount": messages.count,
                "messages": messages.map { message in
                    var msg: [String: Any] = [
                        "direction": message.direction.rawValue,
                        "kind": message.kind.rawValue,
                        "isFinal": message.isFinal,
                    ]
                    if let text = message.textPayload {
                        msg["text"] = text
                    } else {
                        msg["bytes"] = message.payload.count
                    }
                    return msg
                },
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
        if let notAfter = status.notAfter { out["notAfter"] = Self.iso8601.string(from: notAfter) }
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
            methods: (raw["methods"] as? [String]) ?? [],
            isExact: (raw["is_exact"] as? Bool) ?? false,
            hostPattern: (raw["host_pattern"] as? String).flatMap { $0.isEmpty ? nil : $0 },
            query: (raw["query"] as? [String: String]).flatMap { $0.isEmpty ? nil : $0 }
        )
    }

    private static func ruleActions(from raw: [String: Any]) throws -> RuleActions {
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
    private static func substitutions(_ raw: Any?, key: String) throws -> [SubstitutionRule] {
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
                if rule.match.isExact { match["isExact"] = true }
                if let hostPattern = rule.match.hostPattern, !hostPattern.isEmpty { match["hostPattern"] = hostPattern }
                if let query = rule.match.query, !query.isEmpty { match["query"] = query }
                if !rule.match.methods.isEmpty { match["methods"] = rule.match.methods }
                return match
            }(),
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

    private static func substitutionDict(_ sub: SubstitutionRule) -> [String: Any] {
        var out: [String: Any] = ["field": sub.field.rawValue, "match": sub.match, "replacement": sub.replacement]
        if sub.isRegex { out["isRegex"] = true }
        if sub.caseSensitive { out["caseSensitive"] = true }
        return out
    }

    // MARK: - Breakpoint rendering

    private static func matchDict(_ match: RuleMatch) -> [String: Any] {
        var out: [String: Any] = ["urlPattern": match.urlPattern]
        if match.isRegex { out["isRegex"] = true }
        if match.isExact { out["isExact"] = true }
        if let hostPattern = match.hostPattern, !hostPattern.isEmpty { out["hostPattern"] = hostPattern }
        if let query = match.query, !query.isEmpty { out["query"] = query }
        if !match.methods.isEmpty { out["methods"] = match.methods }
        return out
    }

    private static func breakpoint(_ bp: Breakpoint) -> [String: Any] {
        var out: [String: Any] = [
            "id": bp.id.uuidString,
            "match": matchDict(bp.match),
            "onRequest": bp.onRequest,
            "onResponse": bp.onResponse,
            "createdAt": iso8601.string(from: bp.createdAt),
        ]
        if let comment = bp.comment { out["comment"] = comment }
        return out
    }

    private static func pendingBreakpoint(_ pending: PendingBreakpoint) -> [String: Any] {
        var out: [String: Any] = [
            "id": pending.id.uuidString,
            "breakpointId": pending.breakpointID.uuidString,
            "phase": pending.phase.rawValue,
            "heldAt": iso8601.string(from: pending.heldAt),
            "request": [
                "method": pending.method,
                "url": pending.url,
                "headers": pending.requestHeaders.map { ["name": $0.name, "value": $0.value] },
                "body": bodyField(pending.requestBody),
            ],
        ]
        if pending.phase == .response {
            var response: [String: Any] = [
                "headers": (pending.responseHeaders ?? []).map { ["name": $0.name, "value": $0.value] },
                "body": bodyField(pending.responseBody),
            ]
            if let statusCode = pending.statusCode { response["status"] = statusCode }
            out["response"] = response
        }
        return out
    }

    /// Render a body as UTF-8 text, or note that it is binary + how many bytes,
    /// capped so a large held body can't flood the agent's context.
    private static func bodyField(_ data: Data?) -> Any {
        guard let data, !data.isEmpty else { return "" }
        let cap = 16_384
        if let text = String(data: data, encoding: .utf8) {
            if text.count > cap {
                return ["truncated": true, "preview": String(text.prefix(cap)), "bytes": data.count]
            }
            return text
        }
        return ["binary": true, "bytes": data.count]
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
        let body: BodyOverride
        if let bodyString = arguments["body"] as? String {
            body = .replace(Data(bodyString.utf8))
        } else if (arguments["clear_body"] as? Bool) == true {
            body = .clear
        } else {
            body = .keep
        }
        return ReplayOverrides(
            method: arguments["method"] as? String,
            url: arguments["url"] as? String,
            setHeaders: setHeaders,
            removeHeaders: removeHeaders,
            body: body
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
