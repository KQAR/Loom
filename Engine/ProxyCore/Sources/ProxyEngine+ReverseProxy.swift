import Foundation
import LoomSharedModels

/// `ReverseProxyControlling`: local ports that stand in for an upstream origin, for
/// clients that cannot be pointed at a proxy.
///
/// The engine is the façade as usual — `ReverseProxyConfig` owns the endpoint list
/// and its persistence, `ReverseProxyServer` owns the sockets — but the *pairing* of
/// the two lives here, because a configured endpoint that isn't listening and a
/// listener with no config entry are both bugs a caller would experience as "my
/// requests go nowhere".
extension ProxyEngine {
    public func reverseProxies() async -> [ReverseProxyStatus] {
        reverseProxyConfig.snapshot()
    }

    /// Validate → bind → persist, in that order.
    ///
    /// Binding **before** persisting is the load-bearing part: a create that can't
    /// listen must fail loudly rather than leave a config entry whose port refuses
    /// every connection. The usual cause is the port already being taken (often by
    /// the very dev server this endpoint was made for), which the error names.
    public func createReverseProxy(_ endpoint: ReverseProxyEndpoint) async throws -> ReverseProxyStatus {
        var endpoint = endpoint
        // Throws `.invalidReverseProxy` with what is wrong — at create time, not on
        // the first request hours later.
        endpoint.upstream = try ReverseProxyEndpoint.normalizedUpstream(endpoint.upstream)
        guard endpoint.requestedPort >= 0, endpoint.requestedPort <= 65_535 else {
            throw ProxyControlError.invalidReverseProxy("port \(endpoint.requestedPort) is out of range (0–65535; 0 = pick a free one)")
        }
        if let conflict = Self.loomPortConflict(endpoint.requestedPort, proxyPort: boundPort, socksPort: boundSOCKSPort) {
            throw ProxyControlError.invalidReverseProxy(conflict)
        }

        let port: Int
        do {
            port = try await reverseServer.start(
                endpoint: endpoint, store: store, forwarder: forwarder,
                ca: ensureCA(), config: config
            )
        } catch {
            // One wording for every bind in the engine (`BindDiagnosis`). This used
            // to spell its own, which leaked NIO's `bind(descriptor:ptr:bytes:)` and
            // an errno into a sentence an operator reads.
            throw ProxyControlError.invalidReverseProxy(
                BindDiagnosis.describe(error, host: "127.0.0.1", port: endpoint.requestedPort)
            )
        }
        reverseProxyConfig.upsert(endpoint)
        reverseProxyConfig.noteBound(id: endpoint.id, port: port)
        Log.proxy.info("""
        Reverse proxy listening on 127.0.0.1:\(port, privacy: .public) → \
        \(endpoint.upstream, privacy: .public)
        """)
        return ReverseProxyStatus(endpoint: endpoint, boundPort: port)
    }

    public func deleteReverseProxy(id: UUID) async throws {
        guard reverseProxyConfig.endpoint(id: id) != nil else {
            throw ProxyControlError.reverseProxyNotFound(id)
        }
        // Socket first: after this returns, the endpoint must not be reachable. A
        // config entry removed while its listener lived on would keep capturing for
        // an endpoint nothing can see or delete.
        await reverseServer.stop(id: id)
        _ = reverseProxyConfig.delete(id: id)
    }

    /// Whether `port` is one Loom itself holds, and how to say so.
    ///
    /// Taking one of these would "work" and then shadow the thing that owns it. The
    /// two listeners are known by number here; anything else — the MCP control port
    /// above all — is declared by the app through `ReservedPorts`, because the engine
    /// must not know what an MCP server is.
    ///
    /// Checked rather than left to `bind()`: an already-bound port fails with
    /// `Address already in use` anyway, but only if the owner got there first. A
    /// persisted endpoint bound during engine start can beat the MCP server to 9092,
    /// and then the control plane is silently unreachable — the one failure an agent
    /// can never report, since it would have to report it over that port.
    static func loomPortConflict(_ port: Int, proxyPort: Int, socksPort: Int?) -> String? {
        guard port != 0 else { return nil } // 0 = let the OS pick, never a conflict
        if port == proxyPort { return "port \(port) is already Loom's own proxy port" }
        if port == socksPort { return "port \(port) is already Loom's own SOCKS port" }
        if let holder = ReservedPorts.shared.holder(of: port) {
            return "port \(port) is reserved for \(holder)"
        }
        return nil
    }

    /// Bind every persisted endpoint at startup.
    ///
    /// Fails **open per endpoint**: one port being taken must not stop the others or
    /// take the proxy down with it, and the failure is recorded against that endpoint
    /// (`ReverseProxyStatus.error`) so `get_proxy_status` can explain why a client
    /// pointed at it gets connection refused. That is the difference from the create
    /// path, which throws — there, a human or agent is waiting for an answer.
    func startReverseProxies() async {
        for endpoint in reverseProxyConfig.all() {
            // The conflict check runs here too, not only on create: this endpoint was
            // written to disk by an earlier session, possibly before the port belonged
            // to anything, and binding it now is what would shadow the owner.
            if let conflict = Self.loomPortConflict(
                endpoint.requestedPort, proxyPort: boundPort, socksPort: boundSOCKSPort
            ) {
                reverseProxyConfig.noteFailure(id: endpoint.id, error: conflict)
                Log.proxy.error("""
                Reverse proxy for \(endpoint.upstream, privacy: .public) not started: \
                \(conflict, privacy: .public) — delete it or recreate it on a free port
                """)
                continue
            }
            do {
                let port = try await reverseServer.start(
                    endpoint: endpoint, store: store, forwarder: forwarder,
                    ca: ensureCA(), config: config
                )
                reverseProxyConfig.noteBound(id: endpoint.id, port: port)
            } catch {
                let message = BindDiagnosis.describe(error, host: "127.0.0.1", port: endpoint.requestedPort)
                reverseProxyConfig.noteFailure(id: endpoint.id, error: message)
                Log.proxy.error("""
                Reverse proxy for \(endpoint.upstream, privacy: .public) \(message, privacy: .public) \
                — a client pointed at it will get connection refused
                """)
            }
        }
    }
}
