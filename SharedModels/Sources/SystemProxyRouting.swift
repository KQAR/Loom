import Foundation

/// Where this Mac's HTTP/HTTPS traffic is currently pointed.
///
/// Loom is not the only app that sets the system proxy — Charles, Proxyman and
/// whistle all do, and only one of them can win. The old boolean ("is it Loom?")
/// collapsed *off* and *someone else has it* into the same answer, which is the
/// difference between "turn it on" and "quit the other proxy first".
public enum SystemProxyRouting: Equatable, Sendable {
    /// No HTTP/HTTPS system proxy is enabled.
    case off
    /// Both HTTP and HTTPS route through Loom.
    case loom
    /// The system proxy is on but traffic is **not** fully routed to Loom — another
    /// app owns it. `host`/`port` is where the first enabled half points, which is
    /// what a human needs in order to recognize whose it is.
    ///
    /// This also covers a half-applied state (HTTP set, HTTPS not), including one
    /// where the enabled half happens to be Loom's own address: traffic still isn't
    /// fully captured, so reporting `.loom` would be a lie.
    case other(host: String, port: Int)
}

/// The effective system-proxy settings for HTTP and HTTPS, as macOS reports them.
///
/// A snapshot rather than a verdict, so the *consumer* classifies it against the
/// port Loom is actually bound to at that moment. Phone onboarding rebinds the
/// proxy, so a verdict computed when a subscription started can be stale by the
/// time it's delivered.
public struct SystemProxySnapshot: Equatable, Sendable {
    public var httpEnabled: Bool
    public var httpHost: String
    public var httpPort: Int
    public var httpsEnabled: Bool
    public var httpsHost: String
    public var httpsPort: Int

    public init(
        httpEnabled: Bool = false, httpHost: String = "", httpPort: Int = 0,
        httpsEnabled: Bool = false, httpsHost: String = "", httpsPort: Int = 0
    ) {
        self.httpEnabled = httpEnabled
        self.httpHost = httpHost
        self.httpPort = httpPort
        self.httpsEnabled = httpsEnabled
        self.httpsHost = httpsHost
        self.httpsPort = httpsPort
    }

    /// Nothing proxied.
    public static let off = SystemProxySnapshot()

    /// Loom listens on loopback only, so this is the only host that can be Loom.
    public static let loopback = "127.0.0.1"

    /// Classify this snapshot against the port Loom is currently bound to.
    ///
    /// `.loom` requires **both** protocols pointed at Loom. Half-routed is not
    /// routed: HTTPS left on another proxy means every `https://` request bypasses
    /// Loom, which is exactly the "why is my capture empty" case this exists to
    /// answer.
    public func routing(loomPort: Int) -> SystemProxyRouting {
        let httpIsLoom = httpEnabled && httpHost == Self.loopback && httpPort == loomPort
        let httpsIsLoom = httpsEnabled && httpsHost == Self.loopback && httpsPort == loomPort
        if httpIsLoom && httpsIsLoom { return .loom }
        if httpEnabled { return .other(host: httpHost, port: httpPort) }
        if httpsEnabled { return .other(host: httpsHost, port: httpsPort) }
        return .off
    }
}
