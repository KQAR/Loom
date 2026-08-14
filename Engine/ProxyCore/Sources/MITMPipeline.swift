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

    /// - Parameter certificateAuthority: whose per-host TLS context cache has to be
    ///   dropped if this connection turns out to need an HTTP/1.1 downgrade — that
    ///   cached context is what still advertises `h2`. Optional so the pipeline can be
    ///   installed in a test without one; production always has it.
    static func installTLS(
        channel: Channel, host: String, port: Int, sslContext: NIOSSLContext,
        store: FlowStore, forwarder: UpstreamForwarding,
        certificateAuthority: CertificateAuthority? = nil
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
            // One attempt, watched from both sides of the SSL handler: below it for
            // the bytes and the connection ending, above it for NIOSSL's own events.
            // Neither half is sufficient — a client that refuses with an alert raises
            // an error the lower one never sees, and one that just closes the socket
            // raises nothing at all for the upper one to catch.
            let attempt = ClientTLSAttempt()
            try sync.addHandler(NIOSSLServerHandler(context: sslContext), name: "loom.tls", position: .first)
            // **Ahead of the TLS handler, and the order is the whole point**: added
            // at `.first` after it, so it becomes the new head and the bytes it sees
            // are the client's ciphertext. Behind TLS it would see decrypted
            // application data, which by definition only exists after the handshake
            // it exists to watch fail. It observes and forwards, nothing else — the
            // CONNECT-surgery ordering (AGENTS.md § Known Issues) is about what may
            // sit between the client and TLS *writing*, and this writes nothing.
            try sync.addHandler(
                ClientTLSAbortReporter(host: host, port: port, attempt: attempt, store: store),
                position: .first
            )
            // Between the TLS handler and ALPN, so it sees a handshake failure before
            // anything else and while it is still unambiguously a *handshake* failure.
            try sync.addHandler(
                ClientTLSFailureReporter(host: host, port: port, attempt: attempt, store: store)
            )
            try sync.addHandler(
                ApplicationProtocolNegotiationHandler { negotiated in
                    configureIntercepted(
                        channel: channel, negotiated: negotiated,
                        host: host, port: port, store: store, forwarder: forwarder,
                        certificateAuthority: certificateAuthority
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

    /// Install the cleartext HTTP/2 capture stack — h2c with prior knowledge
    /// (RFC 9113 §3.4), i.e. a client that opens with the connection preface and
    /// never negotiates anything.
    ///
    /// This is the **same** stack the ALPN `h2` branch installs, differing only in
    /// what it records (`http://`, no client TLS version) — deliberately so, and
    /// deliberately not a second copy: h2 capture is where the h2↔h1 codec, the
    /// raised `SETTINGS_MAX_HEADER_LIST_SIZE` and the connection-error reporter all
    /// live, and every one of those was a bug before it was a handler.
    ///
    /// Before this existed, `ProtocolSniff` classified the preface as `.opaque` and
    /// the tunnel was relayed unread. That is the exact failure `TunneledHostLog`
    /// was built to make visible rather than the one it was built to accept: gRPC
    /// over cleartext, Go's `h2c.NewHandler`, and an internal service reached by
    /// hostname all recorded no flow at all, which reads identically to a client
    /// that never ran.
    static func installCleartextHTTP2(
        channel: Channel, host: String, port: Int,
        store: FlowStore, forwarder: UpstreamForwarding
    ) -> EventLoopFuture<Void> {
        installHTTP2(
            channel: channel, host: host, port: port, store: store, forwarder: forwarder,
            upstreamTLS: false, clientTLSVersion: nil
        )
    }

    /// Install the decrypted capture stack once ALPN is known. HTTP/2 demuxes each
    /// stream into an HTTP/1-shaped child channel (via the h2↔h1 codec) so the same
    /// `TLSInterceptHandler` captures + forwards it; http/1.1 uses the named h1
    /// stack (kept removable so a WebSocket upgrade can splice a raw relay).
    static func configureIntercepted(
        channel: Channel, negotiated: ALPNResult,
        host: String, port: Int, store: FlowStore, forwarder: UpstreamForwarding,
        certificateAuthority: CertificateAuthority? = nil
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
            return installHTTP2(
                channel: channel, host: host, port: port, store: store, forwarder: forwarder,
                upstreamTLS: true, clientTLSVersion: tlsVersion,
                certificateAuthority: certificateAuthority
            )
        }
        return installHTTP1(
            channel: channel, host: host, port: port, store: store, forwarder: forwarder,
            upstreamTLS: true, clientTLSVersion: tlsVersion
        )
    }

    /// The HTTP/2 capture stack, over TLS or in cleartext. `upstreamTLS` decides
    /// the scheme the exchange is recorded and re-sent under; nothing else in the
    /// stack differs, because nothing else in h2 does.
    private static func installHTTP2(
        channel: Channel, host: String, port: Int,
        store: FlowStore, forwarder: UpstreamForwarding,
        upstreamTLS: Bool, clientTLSVersion: String?,
        certificateAuthority: CertificateAuthority? = nil
    ) -> EventLoopFuture<Void> {
        // Added *before* the codec, so it sits head-side of it: `NIOHTTP2Handler`
        // writes its GOAWAY outbound from its own position, which travels toward the
        // head and never reaches the tail where `HTTP2Frame` values exist. See
        // `HTTP2GoAwayObserver` — the code in that frame is the entire diagnosis for
        // an `unableToParseFrame`, and nothing else carries it.
        let goAway = HTTP2GoAwayCode()
        return channel.eventLoop.makeCompletedFuture {
            try channel.pipeline.syncOperations.addHandler(HTTP2GoAwayObserver(box: goAway))
        }.flatMap {
        channel.configureHTTP2Pipeline(
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
                        upstreamTLS: upstreamTLS,
                        negotiatedProtocol: "HTTP/2", clientTLSVersion: clientTLSVersion
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
                    HTTP2ConnectionErrorReporter(
                        host: host, port: port, store: store, goAway: goAway,
                        certificateAuthority: certificateAuthority
                    )
                )
            }
        }
        }
    }

    /// - Parameter downgrades: whose verdict decides whether an HTTP/1.1 client leg
    ///   here is the client's choice or Loom's. Injected for tests; production reads
    ///   the process-wide registry.
    private static func installHTTP1(
        channel: Channel, host: String, port: Int,
        store: FlowStore, forwarder: UpstreamForwarding, upstreamTLS: Bool,
        clientTLSVersion: String? = nil,
        downgrades: HTTP2DowngradeRegistry = .shared
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
                    upstreamTLS: upstreamTLS, clientTLSVersion: clientTLSVersion,
                    // Only an *intercepted TLS* leg can have been downgraded: the
                    // cleartext installer reaches here too, and h2 was never on
                    // offer there, so an h1 request over it is the client's choice.
                    clientProtocolDowngraded: upstreamTLS && downgrades.isDowngraded(host: host)
                ),
                name: interceptName
            )
        }
    }
}

/// Recording a tunnel as a flow, so an HTTPS connection Loom did *not* read is
/// visible instead of invisible — whether it went past unread on purpose
/// (`record`) or failed because Loom was terminating it (`recordFailure`).
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
        let flow = Flow(
            request: CapturedRequest(method: "CONNECT", url: "https://\(host):\(port)", headers: []),
            startedAt: startedAt,
            outcome: .completed(CapturedResponse(statusCode: 200, headers: []), at: Date()),
            sourceDevice: device(of: client)
        )
        Task { await store.upsert(flow) }
    }

    /// The other way a tunnel ends: Loom terminated the TLS and the **connection
    /// failed** — the client refused Loom's leaf, or the intercepted h2 codec could
    /// not read it. Recorded as the same `CONNECT` row, with the failure in
    /// `Flow.error` instead of a `200`.
    ///
    /// Three rules, and the first two are why this is not just a call to `record`.
    ///
    /// **It is not gated on `observeTunnels`.** That flag asks whether an embedder
    /// wants rows for traffic Loom deliberately passed through, which is a volume
    /// decision about things that *worked*. This is a request that never happened
    /// because Loom was in the path, and an embedder given no row for it has the
    /// same hole the operator had: a client reporting a certificate error against a
    /// capture that denies the host was ever contacted.
    ///
    /// **One row per refused connection, not per host.** A pinned client retries —
    /// a measured session had 736 refusals on one origin — so this is genuinely
    /// noisy, and the aggregate already exists: `TunneledHostLog` holds one entry
    /// per host with a `connections` count, and the console reads that. The table's
    /// grain is the connection everywhere else, and a row that silently stood for
    /// 736 of them would be the more confusing of the two lies.
    ///
    /// **The reason is the operator's next action, not the codec's spelling.** A
    /// refused leaf is repaired by trusting Loom's CA in *that* client or by passing
    /// the host through; the error text says which, and the row's context menu
    /// offers the second.
    static func recordFailure(
        host: String, port: Int, startedAt: Date, client: Channel?,
        error: String, store: FlowStore
    ) {
        let flow = Flow(
            request: CapturedRequest(method: "CONNECT", url: "https://\(host):\(port)", headers: []),
            startedAt: startedAt,
            outcome: .failed(FlowError(error), at: Date(), partialResponse: nil),
            sourceDevice: device(of: client)
        )
        Task { await store.upsert(flow) }
    }

    private static func device(of client: Channel?) -> SourceDevice? {
        client?.remoteAddress?.ipAddress.map { ip in
            SourceDevice(ip: ip, kind: SourceDevice.kind(forIP: ip))
        }
    }

    /// Glue two channels into a byte-transparent relay. Both ends must already be
    /// on the same event loop — `GlueHandler` relays by writing to its partner's
    /// context, which NIO requires happen on that loop.
    ///
    /// - Parameters host/port: what this tunnel is *to*, recorded in
    ///   `RelayedTunnelRegistry` so decrypting that host can end it. Registered here
    ///   rather than at the three call sites for the same reason the splice itself is
    ///   one function: a tunnel that skipped registration would be one an operator
    ///   could never turn into a captured exchange without restarting their client,
    ///   and which call site forgot would be invisible.
    static func glue(
        client: Channel, upstream: Channel,
        host: String, port: Int,
        registry: RelayedTunnelRegistry = .shared
    ) -> EventLoopFuture<Void> {
        registry.register(host: host, port: port, client: client)
        return glueChannels(client: client, upstream: upstream)
    }

    private static func glueChannels(client: Channel, upstream: Channel) -> EventLoopFuture<Void> {
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
