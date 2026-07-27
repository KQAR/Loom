import Foundation
import LoomSharedModels

/// Tools that answer "what is Loom's state, and is my traffic even reaching
/// it": version, proxy status, the system-proxy switch, connected devices, the
/// CA / SSL-interception surface, and the write-action audit log.
///
/// These matter more than they look: an empty capture has two very different
/// causes — nothing happened, or nothing was routed here — and an agent that
/// can't tell them apart guesses.
extension MCPToolExecutor {
    // MARK: - Handlers (one per tool)

    func handleGetVersion(_ arguments: [String: Any]) async throws -> String {
        prettyJSON([
            "app": "Loom",
            "appVersion": appVersion,
            "protocolVersion": protocolVersion,
        ])
    }

    func handleGetProxyStatus(_ arguments: [String: Any]) async throws -> String {
        let status = await engine.status()
        var payload: [String: Any] = [
            "isRunning": status.isRunning,
            "port": status.port,
            "listenHost": status.listenHost,
            "lanReachable": status.isLANReachable,
            "capturedCount": status.capturedCount,
            "isRecording": status.isRecording,
        ]
        // Three-valued on purpose: routed / not routed / can't tell. Collapsing the
        // third into `false` would have an agent "fix" a routing problem that it has
        // no way to observe, and report success it can't verify.
        if let routing {
            payload["systemProxy"] = await routing.isSystemProxyActive() ? "on" : "off"
        } else {
            payload["systemProxy"] = "unavailable"
        }
        return prettyJSON(payload)
    }

    func handleSetSystemProxy(_ arguments: [String: Any]) async throws -> String {
        guard let enabled = arguments["enabled"] as? Bool else {
            throw MCPError.invalidParams("`enabled` must be a boolean")
        }
        guard let routing else {
            throw MCPToolFailure(
                "System-proxy control isn't available here (Loom's engine is running without the app's "
                + "network configuration). Point the client at the proxy manually instead."
            )
        }
        let status = await engine.status()
        guard status.isRunning || !enabled else {
            throw MCPToolFailure("The proxy isn't running, so there is nothing to route traffic to.")
        }
        let result = await routing.setSystemProxy(enabled: enabled)
        guard result.ok else {
            throw MCPToolFailure(result.message ?? "The system proxy change failed.")
        }
        // Read the state back rather than reporting the intent: this path goes through
        // `networksetup` (and an admin prompt on some accounts), and "it returned ok"
        // is not the same as "traffic is now routed here".
        let active = await routing.isSystemProxyActive()
        return prettyJSON([
            "systemProxy": active ? "on" : "off",
            "requested": enabled ? "on" : "off",
            "port": status.port,
            "detail": result.message ?? (enabled ? "This Mac's traffic now routes through Loom." : "Previous proxy settings restored."),
        ])
    }

    func handleListDevices(_ arguments: [String: Any]) async throws -> String {
        let devices = await engine.connectedDevices()
        return prettyJSON(devices.map(Self.deviceSummary))
    }

    /// One entry for `list_devices`. Dates as ISO-8601 so the model can order them.
    static func deviceSummary(_ summary: DeviceSummary) -> [String: Any] {
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

    func handleGetCertificateStatus(_ arguments: [String: Any]) async throws -> String {
        prettyJSON(Self.certificateStatus(await engine.certificateStatus()))
    }

    func handleExportCACertificate(_ arguments: [String: Any]) async throws -> String {
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

    func handleGetSSLScope(_ arguments: [String: Any]) async throws -> String {
        prettyJSON(Self.scope(await engine.sslScope()))
    }

    func handleSetSSLScope(_ arguments: [String: Any]) async throws -> String {
        let current = await engine.sslScope()
        let scope = SSLScope(
            enabled: (arguments["enabled"] as? Bool) ?? current.enabled,
            include: (arguments["include"] as? [String]) ?? current.include,
            exclude: (arguments["exclude"] as? [String]) ?? current.exclude
        )
        await engine.setSSLScope(scope)
        return prettyJSON(Self.scope(scope))
    }

    static func certificateStatus(_ status: CertificateStatus) -> [String: Any] {
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

    static func scope(_ scope: SSLScope) -> [String: Any] {
        [
            "enabled": scope.enabled,
            "include": scope.include,
            "exclude": scope.exclude,
        ]
    }

    func handleGetAuditLog(_ arguments: [String: Any]) async throws -> String {
        let limit = (arguments["limit"] as? Int) ?? 50
        let entries = await engine.recentAuditEntries(limit: limit)
        return prettyJSON(entries.map(Self.auditSummary))
    }

    /// One entry for `get_audit_log`. Timestamp as ISO-8601 so the model can order
    /// them; `arguments` is already-truncated compact JSON (a string, not re-parsed).
    static func auditSummary(_ entry: AuditEntry) -> [String: Any] {
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
}
