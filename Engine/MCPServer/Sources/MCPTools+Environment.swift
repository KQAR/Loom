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
        var payload: [String: Any] = [
            "app": "Loom",
            "appVersion": appVersion,
            // The newest revision served, plus the whole dual-era set — the same list
            // `server/discover` reports, so an agent debugging a version problem sees
            // one answer whichever way it asked.
            "protocolVersion": protocolVersion,
            "supportedProtocolVersions": MCPProtocol.supported,
        ]
        // Which revision the requests actually spoke this run. Omitted entirely when
        // nothing is counting (an executor built without a server around it), because
        // "no legacy traffic" and "no tally" must not read the same.
        if let eraLog {
            payload["protocolTraffic"] = MCPRender.dict(ProtocolTrafficRender(eraLog.snapshot()))
        }
        return prettyJSON(payload)
    }

    func handleGetProxyStatus(_ arguments: [String: Any]) async throws -> String {
        let status = await engine.status()
        var render = ProxyStatusRender(
            isRunning: status.isRunning,
            port: status.port,
            listenHost: status.listenHost,
            lanReachable: status.isLANReachable,
            capturedCount: status.capturedCount,
            isRecording: status.isRecording,
            socksPort: status.socksPort,
            // No routing implementation wired (the engine embedded without the app):
            // "unavailable" says nothing about the machine, which is the honest answer
            // — and a different one from "off", which does.
            systemProxy: "unavailable"
        )
        if let routing {
            switch await routing.systemProxyRouting() {
            case .loom:
                render.systemProxy = "on"
            case .off:
                render.systemProxy = "off"
            case let .other(host, port):
                render.systemProxy = "other"
                render.systemProxyPointsAt = "\(host):\(port)"
            }
            // Whether `set_system_proxy` will stop and wait for a human. The prompt is
            // modal and only dismissable at the machine, so an agent that fires the
            // write blind looks hung for as long as nobody is looking at the screen.
            let helper = await routing.privilegedHelper()
            render.privilegedHelper = helper.rawValue
            if helper != .enabled { render.systemProxyChangePrompts = true }
            // Why it is not working, when Loom knows. "unresponsive" with no reason
            // sends an agent (and a human) guessing at reinstalls.
            render.privilegedHelperDetail = await routing.privilegedHelperDetail()
        }
        // Reported only when there are any, so the common case stays quiet — but when
        // a capture is empty this is often the whole answer, and it used to exist only
        // as an os_log line no agent could reach.
        if status.refusedConnections > 0 {
            render.refusedConnections = status.refusedConnections
            render.recentRefusals = status.recentRefusals.map(ConnectionRefusalRender.init)
        }
        // Same rule as refusals. An endpoint in the list with no `localURL` is not
        // listening (its `error` says why), and that is the "why is nothing captured"
        // case for this feature: a client pointed at a dead endpoint sees connection
        // refused, which reads like Loom isn't running.
        if !status.reverseProxies.isEmpty {
            render.reverseProxies = status.reverseProxies.map(ReverseProxyRender.init)
        }
        return prettyJSON(MCPRender.dict(render))
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
        var payload: [String: Any] = [
            "systemProxy": active ? "on" : "off",
            "requested": enabled ? "on" : "off",
            "port": status.port,
            // Loom deliberately does NOT restore a previous proxy owner on disable
            // (see SystemProxyApplier) — say so, or the agent reports a restore
            // that never happened.
            "detail": result.message ?? (enabled ? "This Mac's traffic now routes through Loom." : "The system proxy is now off. Loom does not restore a previous proxy owner — if another app held it, re-enable it there."),
        ]
        // "Routed" is a fact about the machine, not about the process the operator is
        // debugging, and the difference is invisible from every read surface: the
        // status says `on`, the client's requests reach the server, and Loom captures
        // nothing. Chromium reads the system proxy once per process and never re-reads
        // it, so a browser that was already open keeps going direct — reloading the
        // page does not help, only relaunching does (measured on Chrome 150: identical
        // URL, invisible before the relaunch and captured after). Saying it here is
        // the difference between an agent concluding "nothing happened" and "nothing
        // was pointed at the proxy".
        if enabled {
            payload["runningClientsMayNeedRelaunch"] = true
            payload["routingNote"] = """
            This applies to the machine, not to processes already running. Chrome and \
            other Chromium/Electron apps read the system proxy once at launch and never \
            re-read it, so one that was already open keeps bypassing Loom until it is \
            relaunched — a page reload is not enough. If an expected capture is empty, \
            relaunch the client before concluding the traffic didn't happen. Safari, \
            curl and most CLI tools pick the setting up without a restart.
            """
        }
        return prettyJSON(payload)
    }

    func handleListDevices(_ arguments: [String: Any]) async throws -> String {
        let devices = await engine.connectedDevices()
        return prettyJSON(MCPRender.array(devices.map(DeviceSummaryRender.init)))
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
        // The scope and what it is *not* covering answer one question together, so
        // they ride one call: an agent that has to ask twice will read an empty
        // capture as "the client never ran" before it gets to the second ask.
        let scope = await engine.sslScope()
        return prettyJSON(MCPRender.dict(SSLScopeRender(scope, tunneled: await engine.tunneledHosts())))
    }

    func handleInterceptHost(_ arguments: [String: Any]) async throws -> String {
        guard let host = (arguments["host"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !host.isEmpty
        else {
            throw MCPToolFailure("host is required")
        }
        let outcome = await engine.interceptHost(host)
        var payload: [String: Any] = [
            "host": host,
            "effective": outcome.effective,
            "alreadyIncluded": outcome.alreadyIncluded,
            "enabledInterception": outcome.enabledInterception,
            "scope": Self.scope(await engine.sslScope()),
        ]
        if !outcome.removedExcludes.isEmpty { payload["removedExcludes"] = outcome.removedExcludes }
        // The one case where the write landed and the host still isn't decrypted.
        // Said out loud, because "include contains it" reads as done.
        if let shadow = outcome.shadowedByExclude {
            payload["shadowedByExclude"] = shadow
            payload["detail"] = """
            \(host) is in `include` but still passed through: the exclude glob \
            "\(shadow)" covers it. Narrow that glob with set_ssl_scope if it is safe to.
            """
        }
        return prettyJSON(payload)
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

    // MARK: - Mutual TLS (client certificates)

    func handleListClientCertificates(_ arguments: [String: Any]) async throws -> String {
        let summaries = await engine.clientCertificates()
        return prettyJSON([
            "clientCertificates": MCPRender.array(summaries.map(ClientCertificateRender.init)),
        ])
    }

    func handleSetClientCertificate(_ arguments: [String: Any]) async throws -> String {
        guard let hostPattern = arguments["host_pattern"] as? String, !hostPattern.isEmpty else {
            throw MCPError.invalidParams("`host_pattern` must be a non-empty string")
        }
        guard let base64 = arguments["pkcs12_base64"] as? String,
              let pkcs12 = Data(base64Encoded: base64, options: .ignoreUnknownCharacters),
              !pkcs12.isEmpty
        else {
            throw MCPError.invalidParams("`pkcs12_base64` must be base64 of a PKCS#12 bundle")
        }
        let id: UUID
        if let raw = arguments["id"] as? String {
            guard let parsed = UUID(uuidString: raw) else {
                throw MCPError.invalidParams("`id` must be a UUID")
            }
            id = parsed
        } else {
            id = UUID()
        }

        let certificate = ClientCertificate(
            id: id,
            hostPattern: hostPattern,
            pkcs12: pkcs12,
            passphrase: (arguments["passphrase"] as? String) ?? "",
            label: (arguments["label"] as? String) ?? "",
            isEnabled: (arguments["enabled"] as? Bool) ?? true
        )
        do {
            try await engine.setClientCertificate(certificate)
        } catch let error as ProxyControlError {
            throw MCPToolFailure(error.message)
        }
        // Echo the summary, not the input: it carries the parsed subject and expiry,
        // which is how the operator learns they installed the identity they meant to.
        let summaries = await engine.clientCertificates()
        guard let saved = summaries.first(where: { $0.id == id }) else {
            throw MCPToolFailure("client certificate was not stored")
        }
        return prettyJSON(MCPRender.dict(ClientCertificateRender(saved)).merging(["saved": true]) { _, new in new })
    }

    func handleDeleteClientCertificate(_ arguments: [String: Any]) async throws -> String {
        guard let raw = arguments["id"] as? String, let id = UUID(uuidString: raw) else {
            throw MCPError.invalidParams("`id` must be a UUID")
        }
        do {
            try await engine.deleteClientCertificate(id: id)
        } catch let error as ProxyControlError {
            throw MCPToolFailure(error.message)
        }
        return prettyJSON(["deleted": true, "id": id.uuidString])
    }

    static func certificateStatus(_ status: CertificateStatus) -> [String: Any] {
        MCPRender.dict(CertificateStatusRender(status))
    }

    /// The scope on its own — `get_ssl_scope` adds what is *not* being decrypted.
    static func scope(_ scope: SSLScope) -> [String: Any] {
        MCPRender.dict(SSLScopeRender(scope))
    }

    func handleGetAuditLog(_ arguments: [String: Any]) async throws -> String {
        let limit = (arguments["limit"] as? Int) ?? 50
        let entries = await engine.recentAuditEntries(limit: limit)
        return prettyJSON(MCPRender.array(entries.map(AuditEntryRender.init)))
    }
}
