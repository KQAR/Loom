import Foundation
import LoomSharedModels

/// Handlers for the reverse-proxy endpoints: a local port that stands in for one
/// upstream origin, for clients that can't be pointed at a proxy.
///
/// This is the tool an agent reaches for when `HTTP_PROXY` is set, the routing checks
/// out, and the traffic still isn't there — because the client never reads proxy
/// settings in the first place (Node's `fetch`/undici being the case that shows up
/// most). Rather than asking the human to patch their dev server's source, the agent
/// creates an endpoint and changes one line of config.
extension MCPToolExecutor {
    func handleListReverseProxies(_ arguments: MCPArguments) async throws -> String {
        let endpoints = await engine.reverseProxies()
        return prettyJSON([
            "count": endpoints.count,
            "reverseProxies": endpoints.map(Self.renderReverseProxy),
        ])
    }

    func handleCreateReverseProxy(_ arguments: MCPArguments) async throws -> String {
        let upstream = try arguments.requiredString(
            "upstream", "a string, e.g. \"https://api.example.com\""
        )
        let endpoint = ReverseProxyEndpoint(
            requestedPort: try arguments.int("port", or: 0),
            upstream: upstream,
            label: try arguments.string("label"),
            keepHostHeader: try arguments.bool("keep_host_header", or: false)
        )
        let status: ReverseProxyStatus
        do {
            status = try await engine.createReverseProxy(endpoint)
        } catch let error as ProxyControlError {
            // A domain failure (bad upstream, port taken), not a protocol one — the
            // agent should see it in-band and fix the argument.
            throw MCPToolFailure(error.message)
        }
        var payload = Self.renderReverseProxy(status)
        // The instruction, not just the state: the whole point of the endpoint is the
        // one line the caller now has to change, and spelling it out is what keeps the
        // agent from reporting success while the dev server still bypasses Loom.
        payload["nextStep"] = """
        Point the client at \(status.localURL ?? "the endpoint") instead of \
        \(status.endpoint.upstream) — e.g. a dev server's proxy target. The inbound hop is \
        plain HTTP, so the client needs no CA trust; Loom does the TLS to the upstream. \
        Captured flows carry the upstream URL, so rules and breakpoints match as usual.
        """
        return prettyJSON(payload)
    }

    func handleDeleteReverseProxy(_ arguments: MCPArguments) async throws -> String {
        let id = try arguments.requiredUUID(
            "id", "a reverse-proxy endpoint UUID (see list_reverse_proxies)"
        )
        do {
            try await engine.deleteReverseProxy(id: id)
        } catch let error as ProxyControlError {
            throw MCPToolFailure(error.message)
        }
        return prettyJSON([
            "deleted": id.uuidString,
            "detail": "The port is closed. A client still pointed at it will now get connection refused.",
        ])
    }

    /// One rendering, shared by `get_proxy_status`, `list_reverse_proxies` and
    /// `create_reverse_proxy` — three places an agent reads the same fact, which is
    /// three chances for them to disagree about what "listening" means.
    static func renderReverseProxy(_ status: ReverseProxyStatus) -> [String: Any] {
        MCPRender.dict(ReverseProxyRender(status))
    }
}
