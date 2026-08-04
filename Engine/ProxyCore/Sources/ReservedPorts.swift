import Foundation

/// Ports another part of Loom holds, which a reverse-proxy endpoint must not take.
///
/// The engine already refuses its own two listeners by number (`boundPort`,
/// `boundSOCKSPort`), because binding over them would shadow the proxy itself. The
/// **MCP control port** is the same class of mistake and was not covered: it happened
/// to fail with `Address already in use`, but only because the MCP server had already
/// bound it. Lose that race — an endpoint persisted on 9092 from a previous session,
/// bound at engine start before the MCP server comes up — and Loom starts with its
/// entire control plane unreachable, which is the one failure an agent cannot report,
/// because the agent talks over exactly that port.
///
/// Why a registry rather than a constant in the engine: `ProxyCore` must not know what
/// an MCP server is (dependency direction is one-way, and the engine ships as a
/// library others embed). The app owns the number and declares it here at launch;
/// the engine only knows "this port is taken, and by whom" — which is also what makes
/// the refusal message useful instead of an errno.
///
/// Lock-based and process-wide rather than actor state, for the reason `RefusalLog` is:
/// it must be writable **synchronously at launch**, before either the MCP server or the
/// engine has started, or the reservation loses the very race it exists to prevent.
public final class ReservedPorts: @unchecked Sendable {
    public static let shared = ReservedPorts()

    private let lock = NSLock()
    /// port → what holds it, phrased for an operator ("Loom's MCP control port").
    private var holders: [Int: String] = [:]

    public init() {}

    /// Declare that `port` belongs to `holder`. Idempotent; a second call replaces the
    /// description, so a rebind that moved the port can update it.
    public func reserve(_ port: Int, holder: String) {
        lock.lock()
        defer { lock.unlock() }
        holders[port] = holder
    }

    public func release(_ port: Int) {
        lock.lock()
        defer { lock.unlock() }
        holders[port] = nil
    }

    /// What holds `port`, or nil when nothing has claimed it.
    public func holder(of port: Int) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return holders[port]
    }

    /// For tests, and for an embedder that restarts everything in one process.
    public func reset() {
        lock.lock()
        defer { lock.unlock() }
        holders.removeAll()
    }
}
