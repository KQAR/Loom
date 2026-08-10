import Foundation
import NIOCore
import NIOPosix

/// A failed upstream *connection*, with the two things the raw error never says:
/// where Loom was trying to go, and why the attempt died.
///
/// Sibling of `UpstreamTLSError`, for the hop before it. Without this, every failure
/// short of a handshake reaches the operator as
/// `The operation couldn’t be completed. (NIOPosix.NIOConnectionError error 1.)` —
/// which is what a refused port, an unresolvable name and a black-holed address all
/// look like. Measured on one real capture: 1 885 flows, 94 % of the ring, every one
/// of them that exact sentence.
///
/// The error string is the channel that already reaches every surface — `Flow.error`,
/// so `get_recent_flows` / `get_flow_detail` / HAR / the Inspector, plus the 502 body
/// Loom writes back to the client — which is why the context goes here rather than
/// into a new `Flow` field.
///
/// **It states what happened, not what to do about it.** `NIOConnectionError` carries
/// a per-address list of what each attempt hit, and those errno values are facts.
/// Whether "connection refused" means the dev server is down or the port is wrong is
/// the reader's call — the same rule `UpstreamTLSError` follows, for the same reason.
struct UpstreamConnectionError: Error, LocalizedError {
    let host: String
    let port: Int
    let underlying: Error

    var errorDescription: String? {
        "Could not connect to \(host):\(port) — \(Self.reason(underlying)). Underlying error: \(underlying)"
    }

    /// Wrap `error` when it is a failure to *reach* the origin; hand anything else
    /// straight back.
    ///
    /// Narrow on purpose, exactly like `UpstreamTLSError.wrapping`. A handshake
    /// failure already has a better wrapper, and a connection that dies mid-exchange
    /// (`ForwarderError.connectionClosed`) is not a connect failure — prefixing it
    /// with "could not connect" would describe a connection that demonstrably
    /// happened.
    static func wrapping(_ error: Error, host: String, port: Int) -> Error {
        guard isConnectFailure(error) else { return error }
        return UpstreamConnectionError(host: host, port: port, underlying: error)
    }

    private static func isConnectFailure(_ error: Error) -> Bool {
        if error is NIOConnectionError { return true }
        if let channel = error as? ChannelError, case .connectTimeout = channel { return true }
        return false
    }

    /// A one-line reason, built from whatever the error actually carries.
    ///
    /// `NIOConnectionError` separates name resolution from the per-address attempts,
    /// and the difference matters to the reader: nothing was reachable because the
    /// name has no address is a different problem from every address refusing. When
    /// several addresses failed the same way (v4 and v6 of one host, invariably) the
    /// reasons are de-duplicated, because listing "Connection refused" twice reads as
    /// two different findings.
    static func reason(_ error: Error) -> String {
        if let channel = error as? ChannelError, case let .connectTimeout(amount) = channel {
            return "timed out after \(format(amount))"
        }
        guard let connection = error as? NIOConnectionError else { return String(describing: error) }

        if connection.connectionErrors.isEmpty {
            let dns = [connection.dnsAError, connection.dnsAAAAError]
                .compactMap { $0 }
                .map { describe($0) }
            return dns.isEmpty
                ? "no address to connect to"
                : "could not resolve the host (\(deduplicated(dns).joined(separator: "; ")))"
        }

        // Address included: "refused on ::1 but not on 127.0.0.1" is a real and
        // otherwise invisible shape, and the one an operator debugging a local server
        // needs. Bounded, because a name can resolve to a long list.
        let attempts = connection.connectionErrors.prefix(maxAttemptsListed).map {
            "\(target($0.target)): \(describe($0.error))"
        }
        var text = deduplicated(Array(attempts)).joined(separator: "; ")
        let extra = connection.connectionErrors.count - maxAttemptsListed
        if extra > 0 { text += "; and \(extra) more address(es)" }
        return text
    }

    /// How many per-address failures are named before the rest are counted.
    private static let maxAttemptsListed = 4

    /// The errno name and its text, when the failure is one — `Connection refused
    /// (ECONNREFUSED)` rather than `IOError(errnoCode: 61 …)`.
    private static func describe(_ error: Error) -> String {
        guard let io = error as? IOError else { return String(describing: error) }
        let text = String(cString: strerror(io.errnoCode))
        guard let name = errnoName(io.errnoCode) else { return "\(text) (errno \(io.errnoCode))" }
        return "\(text) (\(name))"
    }

    /// The handful worth naming. An unmapped code still reports its number and its
    /// `strerror` text, so this list is a nicety rather than a dependency.
    private static func errnoName(_ code: CInt) -> String? {
        switch code {
        case ECONNREFUSED: "ECONNREFUSED"
        case ETIMEDOUT: "ETIMEDOUT"
        case EHOSTUNREACH: "EHOSTUNREACH"
        case ENETUNREACH: "ENETUNREACH"
        case ECONNRESET: "ECONNRESET"
        case EHOSTDOWN: "EHOSTDOWN"
        case EADDRNOTAVAIL: "EADDRNOTAVAIL"
        case EACCES: "EACCES"
        default: nil
        }
    }

    private static func target(_ address: SocketAddress) -> String {
        guard let ip = address.ipAddress else { return String(describing: address) }
        return address.port.map { ip.contains(":") ? "[\(ip)]:\($0)" : "\(ip):\($0)" } ?? ip
    }

    private static func deduplicated(_ items: [String]) -> [String] {
        var seen = Set<String>()
        return items.filter { seen.insert($0).inserted }
    }

    private static func format(_ amount: TimeAmount) -> String {
        let ms = amount.nanoseconds / 1_000_000
        return ms >= 1000 ? "\(Double(ms) / 1000)s" : "\(ms)ms"
    }
}
