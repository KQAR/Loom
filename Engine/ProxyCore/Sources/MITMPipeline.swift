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
    static func installTLS(
        channel: Channel, host: String, port: Int, sslContext: NIOSSLContext,
        store: FlowStore, forwarder: UpstreamForwarding
    ) -> EventLoopFuture<Void> {
        let pipeline = channel.pipeline
        return pipeline.addHandler(NIOSSLServerHandler(context: sslContext), name: "loom.tls", position: .first)
            .flatMap {
                let alpn = ApplicationProtocolNegotiationHandler { negotiated in
                    configureIntercepted(
                        channel: channel, negotiated: negotiated,
                        host: host, port: port, store: store, forwarder: forwarder
                    )
                }
                return pipeline.addHandler(alpn)
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
        if case .negotiated("h2") = negotiated {
            return channel.configureHTTP2Pipeline(mode: .server) { streamChannel in
                streamChannel.pipeline.addHandler(HTTP2FramePayloadToHTTP1ServerCodec())
                    .flatMap {
                        streamChannel.pipeline.addHandler(
                            TLSInterceptHandler(host: host, port: port, store: store, forwarder: forwarder)
                        )
                    }
            }.map { _ in () }
        }
        return installHTTP1(channel: channel, host: host, port: port, store: store, forwarder: forwarder, upstreamTLS: true)
    }

    private static func installHTTP1(
        channel: Channel, host: String, port: Int,
        store: FlowStore, forwarder: UpstreamForwarding, upstreamTLS: Bool
    ) -> EventLoopFuture<Void> {
        let pipeline = channel.pipeline
        return pipeline.addHandler(HTTPResponseEncoder(), name: encoderName)
            .flatMap {
                pipeline.addHandler(
                    ByteToMessageHandler(HTTPRequestDecoder(leftOverBytesStrategy: .forwardBytes)),
                    name: decoderName
                )
            }
            .flatMap {
                pipeline.addHandler(
                    TLSInterceptHandler(
                        host: host, port: port, store: store, forwarder: forwarder, upstreamTLS: upstreamTLS
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
    static func record(host: String, port: Int, startedAt: Date, store: FlowStore) {
        let flow = Flow(
            request: CapturedRequest(method: "CONNECT", url: "https://\(host):\(port)", headers: []),
            startedAt: startedAt,
            outcome: .completed(CapturedResponse(statusCode: 200, headers: []), at: Date())
        )
        Task { await store.upsert(flow) }
    }

    /// Glue two channels into a byte-transparent relay. Both ends must already be
    /// on the same event loop — `GlueHandler` relays by writing to its partner's
    /// context, which NIO requires happen on that loop.
    static func glue(client: Channel, upstream: Channel) -> EventLoopFuture<Void> {
        let (clientGlue, upstreamGlue) = GlueHandler.matchedPair()
        return client.pipeline.addHandler(clientGlue)
            .and(upstream.pipeline.addHandler(upstreamGlue))
            .map { _ in () }
    }
}
