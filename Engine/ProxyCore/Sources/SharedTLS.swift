import Foundation
import NIOSSL

/// One shared client-side `NIOSSLContext` for every upstream TLS leg (HTTPS
/// forwarding + wss origination). Building a context parses the system trust
/// store — tens of milliseconds and an allocation — so doing it per request was
/// pure hot-path waste. The context is immutable and thread-safe; only the
/// per-connection `NIOSSLClientHandler` must be fresh.
enum SharedTLS {
    /// Force-try is safe: the default client configuration is fixed and valid;
    /// if it ever can't build, every HTTPS forward is broken and crashing loudly
    /// at startup is preferable to a silent per-request failure.
    static let clientContext: NIOSSLContext =
        try! NIOSSLContext(configuration: .makeClientConfiguration())

    /// Whether `host` is an IPv4/IPv6 literal rather than a name.
    ///
    /// The reason this is shared rather than a private helper on each caller:
    /// `NIOSSLClientHandler(context:serverHostname:)` **throws**
    /// `cannotUseIPAddressInSNI` when handed a literal, since SNI carries names only.
    /// Every upstream-TLS site therefore has to pass `nil` for a literal, and a site
    /// that forgets doesn't fail loudly — it fails at handler construction, which is
    /// exactly where a `try?` turns into a plaintext connection to a TLS server.
    /// `NIOStreamingForwarder` got this right and `WebSocketRelay` did not; one
    /// definition is how the next upstream-TLS caller inherits the right behaviour.
    static func isIPLiteral(_ host: String) -> Bool {
        var v4 = in_addr(), v6 = in6_addr()
        return host.withCString { inet_pton(AF_INET, $0, &v4) == 1 || inet_pton(AF_INET6, $0, &v6) == 1 }
    }
}
