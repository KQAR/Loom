import Foundation

/// What may be asked of the proxy's listen port, in one place.
///
/// It lives in SharedModels because both writers need it and they must agree: the
/// toolbar's address editor validates while someone types, the engine validates what
/// actually reaches a socket, and `set_proxy_port` needs the same answer to explain a
/// refusal to an agent. Two copies of these rules would be two sets of edge cases.
public enum ListenPortRules {
    /// What Loom can bind without being root. Below 1024 the bind fails with `EACCES`,
    /// which reads as "port in use" and sends someone hunting for a process that isn't
    /// there. The ceiling leaves room for the SOCKS listener above it.
    public static let range = 1024...65534

    /// Why this port can't be used, or nil when it can.
    ///
    /// **Every check is about the pair.** The SOCKS listener conventionally rides one
    /// port above the proxy, so a port whose neighbour is taken binds the HTTP side and
    /// then fails — or worse, quietly takes a port something else was about to want.
    ///
    /// - Parameters:
    ///   - reserved: ports already claimed by name, for a refusal that can say *what*
    ///     holds them (`ReservedPorts` — Loom's own MCP control port is the one that
    ///     matters, since taking it disconnects the agent doing the asking).
    ///   - inUseByLoom: ports Loom is already listening on for something else — its
    ///     reverse-proxy endpoints.
    public static func refusal(
        for port: Int,
        reserved: [Int: String] = [:],
        inUseByLoom: Set<Int> = []
    ) -> String? {
        guard range.contains(port) else {
            return "Pick a port between \(range.lowerBound) and \(range.upperBound)."
        }
        for candidate in [port, port + 1] {
            if let holder = reserved[candidate] {
                return candidate == port
                    ? "Port \(port) is \(holder)."
                    : "Port \(candidate) is \(holder), and the SOCKS listener would take it."
            }
        }
        if inUseByLoom.contains(port) || inUseByLoom.contains(port + 1) {
            return "A reverse-proxy endpoint already listens there."
        }
        return nil
    }

    /// The MCP control plane's fixed loopback port, named here so a refusal can
    /// explain itself. `MCPServer.defaultPort` is the definition — AppFeature does not
    /// depend on MCPServer, and the engine registers the real one through
    /// `ReservedPorts` at launch, which is what the *engine's* check reads. This
    /// constant exists so the human's editor can refuse it while typing, before
    /// anything is asked of the engine.
    public static let mcpControlPort = 9092

    /// The SOCKS listener's port for a given proxy port. One place, because the
    /// convention is asserted in three (the app's start, a rebind, and validation).
    public static func socksPort(besides port: Int) -> Int { port + 1 }
}
