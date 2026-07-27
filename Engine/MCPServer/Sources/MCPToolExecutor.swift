import Foundation
import LoomSharedModels

/// Dispatches MCP `tools/call` requests to the proxy engine and renders results.
/// Read tools inspect captured traffic; `replay_flow` is the write tool that
/// makes Loom "AI-operable" rather than merely AI-readable.
///
/// The tool surface is split by domain across `MCPToolSchemas` (what is
/// advertised) and `MCPTools+*` (what each tool does). This file holds only the
/// executor's state and the dispatch choke point — including the audit recording
/// that every write tool goes through.
struct MCPToolExecutor {
    let engine: ProxyControlling
    let appVersion: String
    let protocolVersion: String

    /// Injected by the app; nil where system-proxy control isn't available (an
    /// embedder driving the engine as a library, or a test).
    var routing: SystemRoutingControlling?

    /// Name → handler registry. Paired with the same-named entries in
    /// `toolDefinitions`; `MCPServerTests` asserts the two never drift (every
    /// advertised tool has a handler). Dispatch is a lookup, not a growing switch.
    static let handlers: [String: (MCPToolExecutor, [String: Any]) async throws -> String] = [
        "get_version": { ex, args in try await ex.handleGetVersion(args) },
        "get_proxy_status": { ex, args in try await ex.handleGetProxyStatus(args) },
        "set_system_proxy": { ex, args in try await ex.handleSetSystemProxy(args) },
        "list_devices": { ex, args in try await ex.handleListDevices(args) },
        "get_recent_flows": { ex, args in try await ex.handleGetRecentFlows(args) },
        "get_stats": { ex, args in try await ex.handleGetStats(args) },
        "wait_for_flow": { ex, args in try await ex.handleWaitForFlow(args) },
        "wait_for_pending": { ex, args in try await ex.handleWaitForPending(args) },
        "get_flow_detail": { ex, args in try await ex.handleGetFlowDetail(args) },
        "get_audit_log": { ex, args in try await ex.handleGetAuditLog(args) },
        "set_recording": { ex, args in try await ex.handleSetRecording(args) },
        "clear_flows": { ex, args in try await ex.handleClearFlows(args) },
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
        "import_har": { ex, args in try await ex.handleImportHAR(args) },
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
        "set_system_proxy",
        "set_recording",
        "clear_flows",
        "arm_breakpoint",
        "disarm_breakpoint",
        "resume",
        "export_ca_certificate",
        "set_ssl_scope",
        "export_har",
        "import_har",
        "set_rule",
        "delete_rule",
        "set_rules_enabled",
        "set_group_enabled",
    ]

    /// Dispatch one `tools/call`. Returns the tool's text result, or throws a
    /// `MCPError` describing why the call could not be dispatched.
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
    static func auditArguments(_ arguments: [String: Any]) -> String {
        guard !arguments.isEmpty else { return "{}" }
        guard JSONSerialization.isValidJSONObject(arguments),
              let data = try? JSONSerialization.data(withJSONObject: arguments, options: [.sortedKeys]),
              let string = String(data: data, encoding: .utf8)
        else { return String(describing: arguments) }
        return string
    }

    func prettyJSON(_ value: Any) -> String {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]),
              let string = String(data: data, encoding: .utf8)
        else {
            return String(describing: value)
        }
        return string
    }
}
