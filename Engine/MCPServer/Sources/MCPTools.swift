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

        default:
            throw MCPError.methodNotFound("unknown tool: \(name)")
        }
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
