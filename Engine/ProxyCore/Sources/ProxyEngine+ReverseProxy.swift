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
        // A port Loom is already using for something else would "work" and then
        // shadow the proxy or the MCP server, which is far worse than refusing.
        if endpoint.requestedPort != 0, endpoint.requestedPort == boundPort || endpoint.requestedPort == boundSOCKSPort {
            throw ProxyControlError.invalidReverseProxy(
                "port \(endpoint.requestedPort) is already Loom's own \(endpoint.requestedPort == boundPort ? "proxy" : "SOCKS") port")
        }

        let port: Int
        do {
            port = try await reverseServer.start(
                endpoint: endpoint, store: store, forwarder: forwarder,
                ca: ensureCA(), config: config
            )
        } catch {
            throw ProxyControlError.invalidReverseProxy(
                "could not listen on port \(endpoint.requestedPort): \(error). Is something else already using it?")
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

    /// Bind every persisted endpoint at startup.
    ///
    /// Fails **open per endpoint**: one port being taken must not stop the others or
    /// take the proxy down with it, and the failure is recorded against that endpoint
    /// (`ReverseProxyStatus.error`) so `get_proxy_status` can explain why a client
    /// pointed at it gets connection refused. That is the difference from the create
    /// path, which throws — there, a human or agent is waiting for an answer.
    func startReverseProxies() async {
        for endpoint in reverseProxyConfig.all() {
            do {
                let port = try await reverseServer.start(
                    endpoint: endpoint, store: store, forwarder: forwarder,
                    ca: ensureCA(), config: config
                )
                reverseProxyConfig.noteBound(id: endpoint.id, port: port)
            } catch {
                let message = "could not listen on port \(endpoint.requestedPort): \(error)"
                reverseProxyConfig.noteFailure(id: endpoint.id, error: message)
                Log.proxy.error("""
                Reverse proxy for \(endpoint.upstream, privacy: .public) \(message, privacy: .public) \
                — a client pointed at it will get connection refused
                """)
            }
        }
    }
}
