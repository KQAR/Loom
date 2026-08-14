import Foundation
import NIOCore
import NIOHTTP1
import NIOHTTP2
import NIOSSL
import NIOTLS
import LoomSharedModels

/// Installing the capture stack on a channel that is already carrying raw bytes
/// for a known host:port — the shape both entry points converge on.
///
/// Two callers reach here: `ProxyHandler` after it has acked a `CONNECT` and
/// stripped the proxy's HTTP framing, and `SOCKSConnectionHandler` after its
/// handshake and protocol sniff. They differ only in *how* they learned the
/// destination, so the pipeline they install must be one definition — the handler
/// names below are load-bearing (a WebSocket upgrade removes them by name), and
/// two copies of that list is how a `wss://` upgrade over one entry point breaks
/// while the other keeps working.
enum MITMPipeline {
    /// Handler names the intercepted h1 stack installs; `TLSInterceptHandler`
    /// removes exactly these when a WebSocket upgrade splices in a raw relay.
    static let encoderName = "loom.mitm.encoder"
    static let decoderName = "loom.mitm.decoder"
    static let interceptName = "loom.mitm.intercept"

    /// Terminate TLS with a leaf minted for `host`, then install the decrypted
    /// capture stack (branching on the negotiated ALPN protocol).
    ///
    /// The channel must have no HTTP framing left on it: the TLS handler goes in
    /// at the pipeline head, so anything upstream of it would see ciphertext.

    // MARK: - HTTP/2 server settings

    /// Largest request field section Loom will decode, in place of SwiftNIO's
    /// `SETTINGS_MAX_HEADER_LIST_SIZE` default of 16 KB (`HPACKDecoder
    /// .defaultMaxHeaderListSize`, whose own comment calls the value "somewhat
    /// arbitrary").
    ///
    /// **A proxy must not be stricter than the origin it stands in front of.** Any
    /// limit Loom enforces that the real server does not turns into a failure that
    /// exists *only while Loom is in the path* — which is the one kind of bug a
    /// debugging tool must never introduce, because the operator will spend the
    /// afternoon blaming their app.
    ///
    /// Measured, not theorised: a real app whose session cookies had grown to
    /// ~15–31 KB refreshed its home screen, the HEADERS block blew past 16 KB, and
    /// the request **vanished** — no RST_STREAM, no GOAWAY, no 431, no flow. The
    /// app spun forever and the capture said the request had never happened. It
    /// reproduces in one line: a 20 KB `Cookie` header through the proxy hangs
    /// until the client's own timeout, while 1 KB answers in 150 ms.
    ///
    /// RFC 9113 §6.5.2 makes this setting *advisory* — a client may legitimately
    /// exceed it — and §10.5.1 says a server unwilling to handle a field section
    /// that large **MUST** respond (431, or a stream error), never drop it. 1 MB is
    /// well past what any client sends and still bounded, because the field section
    /// is buffered before it can be rejected.
    static let maxHeaderListSize = 1 << 20

    private static var h2ServerSettings: [HTTP2Setting] {
        [
            HTTP2Setting(parameter: .maxConcurrentStreams, value: 100),
            HTTP2Setting(parameter: .maxHeaderListSize, value: maxHeaderListSize),
        ]
    }

    static func installTLS(
        channel: Channel, host: String, port: Int, sslContext: NIOSSLContext,
        store: FlowStore, forwarder: UpstreamForwarding
    ) -> EventLoopFuture<Void> {
        // Every `addHandler` here goes through `syncOperations` inside a
        // `makeCompletedFuture` body, which — unlike `EventLoopFuture.flatMap`'s — is
        // not `@Sendable`. That is the point: NIO's handler types are not `Sendable`
        // (they are event-loop confined), so building one outside and capturing it in
        // a `@Sendable` closure is exactly what strict concurrency objects to. Building
        // it inside means nothing crosses. Both callers already run on this channel's
        // loop, which `syncOperations` requires.
        channel.eventLoop.makeCompletedFuture {
            let sync = channel.pipeline.syncOperations
            try sync.addHandler(NIOSSLServerHandler(context: sslContext), name: "loom.tls", position: .first)
            // Between the TLS handler and ALPN, so it sees a handshake failure before
            // anything else and while it is still unambiguously a *handshake* failure.
            try sync.addHandler(ClientTLSFailureReporter(host: host, port: port))
            try sync.addHandler(
                ApplicationProtocolNegotiationHandler { negotiated in
                    configureIntercepted(
                        channel: channel, negotiated: negotiated,
                        host: host, port: port, store: store, forwarder: forwarder
                    )
                }
            )
        }
    }

    /// Install the cleartext HTTP capture stack — same handlers as the decrypted
    /// h1 path, but the exchange is recorded and re-sent as `http://`.
    ///
    /// Reached whenever a tunnel turns out to carry cleartext HTTP (see
    /// `TunnelSniffHandler`): over SOCKS, and over a `CONNECT` whose payload isn't
    /// TLS — a browser's `ws://` being the case that matters. A plaintext request
    /// arriving *directly* on the HTTP proxy port never needs this, because it carries
    /// its destination in an absolute request URI.
    static func installPlaintextHTTP(
        channel: Channel, host: String, port: Int,
        store: FlowStore, forwarder: UpstreamForwarding
    ) -> EventLoopFuture<Void> {
        installHTTP1(channel: channel, host: host, port: port, store: store, forwarder: forwarder, upstreamTLS: false)
    }

    /// Install the decrypted capture stack once ALPN is known. HTTP/2 demuxes each
    /// stream into an HTTP/1-shaped child channel (via the h2↔h1 codec) so the same
    /// `TLSInterceptHandler` captures + forwards it; http/1.1 uses the named h1
    /// stack (kept removable so a WebSocket upgrade can splice a raw relay).
    static func configureIntercepted(
        channel: Channel, negotiated: ALPNResult,
        host: String, port: Int, store: FlowStore, forwarder: UpstreamForwarding
    ) -> EventLoopFuture<Void> {
        // Read once, here, and handed down. This runs on the connection channel
        // after the handshake — the only point where both facts are available:
        // ALPN has settled, and the `NIOSSLServerHandler` the version comes from
        // is in *this* pipeline. An h2 stream channel is a child with no TLS
        // handler of its own, so a per-request read there answers nil.
        let tlsVersion = UpstreamTLSObserver.versionName(
            (try? channel.pipeline.syncOperations.nioSSL_tlsVersion()) ?? nil
        )
        if case .negotiated("h2") = negotiated {
            return channel.configureHTTP2Pipeline(
                mode: .server, initialLocalSettings: h2ServerSettings
            ) { streamChannel in
                streamChannel.eventLoop.makeCompletedFuture {
                    let sync = streamChannel.pipeline.syncOperations
                    try sync.addHandler(HTTP2FramePayloadToHTTP1ServerCodec())
                    // The codec hands the request over as an HTTP/1.1 head, so the
                    // negotiated protocol has to be stated rather than derived —
                    // otherwise every h2 exchange records itself as HTTP/1.1, which
                    // is true of the shape and false about the client.
                    try sync.addHandler(
                        TLSInterceptHandler(
                            host: host, port: port, store: store, forwarder: forwarder,
                            negotiatedProtocol: "HTTP/2", clientTLSVersion: tlsVersion
                        )
                    )
                }
            }.flatMap { _ in
                // At the tail of the *connection* channel: a codec error travels
                // inbound from `NIOHTTP2Handler`, and with nothing here it used to
                // reach the end of the pipeline and vanish, leaving the client to
                // wait on a request that would never be answered.
                channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.addHandler(
                        HTTP2ConnectionErrorReporter(host: host, port: port)
                    )
                }
            }
        }
        return installHTTP1(
            channel: channel, host: host, port: port, store: store, forwarder: forwarder,
            upstreamTLS: true, clientTLSVersion: tlsVersion
        )
    }

    private static func installHTTP1(
        channel: Channel, host: String, port: Int,
        store: FlowStore, forwarder: UpstreamForwarding, upstreamTLS: Bool,
        clientTLSVersion: String? = nil
    ) -> EventLoopFuture<Void> {
        channel.eventLoop.makeCompletedFuture {
            let sync = channel.pipeline.syncOperations
            try sync.addHandler(HTTPResponseEncoder(), name: encoderName)
            try sync.addHandler(
                ByteToMessageHandler(HTTPRequestDecoder(leftOverBytesStrategy: .forwardBytes)),
                name: decoderName
            )
            try sync.addHandler(
                TLSInterceptHandler(
                    host: host, port: port, store: store, forwarder: forwarder,
                    upstreamTLS: upstreamTLS, clientTLSVersion: clientTLSVersion
                ),
                name: interceptName
            )
        }
    }
}

/// Recording an un-decrypted tunnel as a flow, so HTTPS (or opaque TCP) activity
/// Loom deliberately did *not* read is still visible instead of invisible.
///
/// Shared by both entry points: the `CONNECT` method marks it (a real captured
/// request never carries one), and having one definition means an embedder's
/// `observeTunnels` means the same thing whichever listener the client used.
enum TunnelFlow {
    /// - Parameter client: the channel the tunnel was opened on, for attribution. A
    ///   tunnel carries no request head, so there is no `User-Agent` to type the device
    ///   from and no `SourceApp` at all — but the peer's address is right there, and
    ///   without it the row is unreachable from the surface it exists for: filtering the
    ///   table to a device (the sidebar's most-used filter, and `get_recent_flows`'s
    ///   `device_ip`) dropped every CONNECT row, so "what is this phone not showing me"
    ///   answered nothing.
    static func record(host: String, port: Int, startedAt: Date, client: Channel?, store: FlowStore) {
        let device = client?.remoteAddress?.ipAddress.map { ip in
            SourceDevice(ip: ip, kind: SourceDevice.kind(forIP: ip))
        }
        let flow = Flow(
            request: CapturedRequest(method: "CONNECT", url: "https://\(host):\(port)", headers: []),
            startedAt: startedAt,
            outcome: .completed(CapturedResponse(statusCode: 200, headers: []), at: Date()),
            sourceDevice: device
        )
        Task { await store.upsert(flow) }
    }

    /// Glue two channels into a byte-transparent relay. Both ends must already be
    /// on the same event loop — `GlueHandler` relays by writing to its partner's
    /// context, which NIO requires happen on that loop.
    static func glue(client: Channel, upstream: Channel) -> EventLoopFuture<Void> {
        // The pair is built *inside* the loop-bound body for the same reason as
        // `MITMPipeline`'s handlers: `GlueHandler` is event-loop confined and not
        // `Sendable`. Adding both on the one loop is also what the shared-loop
        // requirement above already demands, so this is not a new constraint.
        client.eventLoop.makeCompletedFuture {
            let (clientGlue, upstreamGlue) = GlueHandler.matchedPair()
            try client.pipeline.syncOperations.addHandler(clientGlue)
            try upstream.pipeline.syncOperations.addHandler(upstreamGlue)
        }
    }
}
