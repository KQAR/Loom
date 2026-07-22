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
}
