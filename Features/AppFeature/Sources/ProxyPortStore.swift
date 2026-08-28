import Foundation

/// Persists the port the proxy listens on, so a choice survives relaunch. Absent
/// key → 9090, which is what every doc, the skill and the empty state's `curl -x`
/// hint have always printed. Side-effecting, so the reducer touches it only from
/// effects (same shape as `LANCaptureStore`).
enum ProxyPortStore {
    static let defaultPort = 9090
    private static let key = "com.loom.proxyPort"

    /// The MCP control plane's fixed loopback port. Named here rather than imported
    /// because AppFeature does not depend on MCPServer — it is duplicated on purpose
    /// and `MCPServer.defaultPort` is the definition; this is a guard against the
    /// human picking a port that would silently take the agent's endpoint away.
    static let mcpPort = 9092

    /// What Loom can bind without being root. Below 1024 the bind fails with
    /// `EACCES`, which would read as "port in use" and send someone hunting for a
    /// process that isn't there.
    static let range = 1024...65534

    static func load() -> Int {
        let stored = UserDefaults.standard.integer(forKey: key)
        return validate(stored, reservedPorts: []) == nil ? stored : defaultPort
    }

    static func save(_ port: Int) {
        UserDefaults.standard.set(port, forKey: key)
    }

    /// Why this port can't be used, or nil when it can. **The SOCKS listener rides
    /// one port above the HTTP proxy** (`ProxyClient.liveValue` starts it at
    /// `port + 1`), so every check here is about the *pair* — a port whose neighbour
    /// is taken binds the HTTP side and then fails, or worse, quietly takes a port
    /// something else was about to want.
    static func validate(_ port: Int, reservedPorts: Set<Int>) -> String? {
        guard range.contains(port) else {
            return "Pick a port between \(range.lowerBound) and \(range.upperBound)."
        }
        if port == mcpPort || port + 1 == mcpPort {
            return "\(mcpPort) is the MCP endpoint an agent connects to — the SOCKS listener would take it."
        }
        if reservedPorts.contains(port) || reservedPorts.contains(port + 1) {
            return "A reverse-proxy endpoint already listens there."
        }
        return nil
    }
}
