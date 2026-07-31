import Foundation
import NIOCore
import NIOPosix
import NIOHTTP1
import NIOHTTP2
import NIOTLS
import NIOSSL
import LoomSharedModels

/// Terminates one proxied client connection. For plain HTTP it captures the
/// exchange and forwards it. For CONNECT it either MITM-decrypts the TLS (when
/// the host is in the SSL-proxying scope and a CA is available) or opens a blind
/// TCP tunnel (pinned / out-of-scope / interception off).
final class ProxyHandler: ChannelInboundHandler, RemovableChannelHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private let store: FlowStore
    private let group: EventLoopGroup
    private let forwarder: UpstreamForwarding
    private let ca: CertificateAuthority?
    private let config: InterceptionConfig
    /// When true, an un-decrypted (blind) CONNECT tunnel is recorded as a flow so
    /// a consumer can see the HTTPS activity even though it wasn't MITM-decrypted.
    /// Off by default — the app UI doesn't want CONNECT noise; embedders opt in.
    private let observeTunnels: Bool

    private var requestHead: HTTPRequestHead?
    private var requestURL: URL?
    private var connectHead: HTTPRequestHead?
    /// Live bridge for the current request's streamed body — created lazily on the
    /// first body chunk (so h2 bodies with no Content-Length still stream); nil for a
    /// bodyless request. Chunks are pumped in and pulled by the forwarder under
    /// back-pressure.
    private var bodyBridge: RequestBodyBridge?
    /// Set when the request head was malformed so the trailing body/end are ignored.
    private var droppingRequest = false

    init(
        store: FlowStore,
        group: EventLoopGroup,
        forwarder: UpstreamForwarding,
        ca: CertificateAuthority?,
        config: InterceptionConfig,
        observeTunnels: Bool = false
    ) {
        self.store = store
        self.group = group
        self.forwarder = forwarder
        self.ca = ca
        self.config = config
        self.observeTunnels = observeTunnels
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case let .head(head):
            if head.method == .CONNECT {
                // Defer the pipeline surgery until `.end`, so the decoder has
                // finished emitting the CONNECT's HTTP parts before we swap it out.
                connectHead = head
                return
            }
            // Proxied requests carry an absolute URI in the request line.
            guard let url = URL(string: head.uri), url.scheme != nil else {
                HTTPUtil.writeResponse(channel: context.channel, status: 400, headers: [],
                                       body: Data("Loom: expected absolute request URI\n".utf8), keepAlive: false)
                droppingRequest = true
                return
            }
            requestHead = head
            requestURL = url
        case var .body(chunk):
            if droppingRequest { return }
            // First body chunk: begin streaming. Pausing auto-read (mirrors the
            // TLS-swap pause) means the only reads are the ones the bridge asks for as
            // the forwarder drains, so a fast uploader can't outrun a slow upstream.
            if bodyBridge == nil {
                guard let head = requestHead, let url = requestURL else { return }
                let bridge = RequestBodyBridge(capture: RequestBodyCapture())
                bridge.attach(channel: context.channel)
                bodyBridge = bridge
                _ = context.channel.setOption(ChannelOptions.autoRead, value: false)
                startExchange(channel: context.channel, head: head, url: url,
                              body: .stream(bridge.chunks, contentLength: RequestBodyStreaming.contentLength(head)),
                              capture: bridge.capture)
            }
            if let bytes = chunk.readBytes(length: chunk.readableBytes) { bodyBridge?.yield(Data(bytes)) }
        case .end:
            if let connectHead {
                self.connectHead = nil
                handleConnect(context: context, head: connectHead)
                return
            }
            if let bodyBridge {
                bodyBridge.finish()
                self.bodyBridge = nil
                _ = context.channel.setOption(ChannelOptions.autoRead, value: true) // resume for keep-alive
                requestHead = nil; requestURL = nil
                return
            }
            if droppingRequest { droppingRequest = false; requestHead = nil; requestURL = nil; return }
            guard let head = requestHead, let url = requestURL else { return }
            startExchange(channel: context.channel, head: head, url: url, body: .bytes(nil), capture: nil)
            requestHead = nil; requestURL = nil
        }
    }

    /// A body stream still in flight when the connection goes away has to be
    /// terminated here — nothing else will. See `RequestBodyBridge.abort(reason:)`
    /// for why letting it deinit unfinished is fatal.
    func channelInactive(context: ChannelHandlerContext) {
        abortBodyStream(reason: "connection closed")
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        abortBodyStream(reason: "\(error)")
        context.fireErrorCaught(error)
    }

    private func abortBodyStream(reason: String) {
        guard let bridge = bodyBridge else { return }
        bodyBridge = nil
        requestHead = nil
        requestURL = nil
        bridge.abort(reason: reason)
    }

    // MARK: - Plain HTTP forwarding

    private func startExchange(channel: Channel, head: HTTPRequestHead, url: URL, body: RequestBody, capture: RequestBodyCapture?) {
        let wsPort = url.port ?? (url.scheme?.lowercased() == "wss" ? 443 : 80)
        CapturedExchange.handle(
            channel: channel, head: head, body: body, bodyCapture: capture,
            routing: CapturedExchange.Routing(
                url: url,
                urlString: head.uri,
                webSocketHost: url.host ?? "",
                webSocketPort: wsPort,
                webSocketUpstreamTLS: url.scheme?.lowercased() == "wss",
                webSocketRequestPath: Self.originForm(url),
                webSocketRemoveHandlerNames: ["loom.http.encoder", "loom.http.decoder", "loom.proxy"]
            ),
            store: store, forwarder: forwarder
        )
    }

    /// Origin-form request target (path + query) for an absolute proxied URL.
    private static func originForm(_ url: URL) -> String {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url.path.isEmpty ? "/" : url.path
        }
        let path = components.percentEncodedPath.isEmpty ? "/" : components.percentEncodedPath
        if let query = components.percentEncodedQuery { return "\(path)?\(query)" }
        return path
    }

    // MARK: - CONNECT

    private func handleConnect(context: ChannelHandlerContext, head: HTTPRequestHead) {
        let (host, port) = Self.parseAuthority(head.uri)
        if let ca, config.shouldIntercept(host: host) {
            interceptTLS(context: context, host: host, port: port, ca: ca)
        } else {
            openTunnel(context: context, host: host, port: port)
        }
    }

    private static func parseAuthority(_ uri: String) -> (host: String, port: Int) {
        let parts = uri.split(separator: ":")
        let host = String(parts.first ?? "")
        let port = parts.count > 1 ? (Int(parts[1]) ?? 443) : 443
        return (host, port)
    }

    // MARK: - MITM interception

    /// Acknowledge the CONNECT, then swap the plaintext HTTP framing for a TLS
    /// server (presenting the host's leaf) followed by fresh HTTP framing and the
    /// capturing handler. Auto-read is paused across the swap so the client's
    /// ClientHello can't reach the old HTTP decoder mid-reconfiguration.
    private func interceptTLS(context: ChannelHandlerContext, host: String, port: Int, ca: CertificateAuthority) {
        let sslContext: NIOSSLContext
        do {
            sslContext = try ca.serverContext(for: host)
        } catch {
            // Fail open: blind-tunnel so the site still works, but record why this
            // host wasn't intercepted (otherwise "nothing captured" is a mystery).
            Log.tls.error("Leaf mint failed for \(host, privacy: .public); blind-tunneling: \(String(describing: error))")
            openTunnel(context: context, host: host, port: port)
            return
        }

        let channel = context.channel
        let store = self.store
        let forwarder = self.forwarder
        let pipeline = channel.pipeline

        // Pause reads until the TLS handler is installed so the client's ClientHello
        // can't reach a plaintext handler.
        _ = channel.setOption(ChannelOptions.autoRead, value: false)

        // Strip all HTTP framing first, then send the CONNECT ack as RAW bytes:
        // routing it through HTTPResponseEncoder would chunk-frame the bodyless 200
        // and inject `0\r\n\r\n` into the tunnel, corrupting the client's first TLS
        // record. Only then install the TLS terminator + fresh HTTP + capture stack.
        // An already-removed handler is fine to skip (`recover`), but the chain as a
        // whole must succeed before the ack: acking with the encoder still installed
        // would frame the tunnel bytes and corrupt the client's first TLS record.
        let removals = ["loom.http.decoder", "loom.http.encoder", "loom.proxy"].map { name in
            pipeline.removeHandler(name: name).recover { _ in () }
        }
        EventLoopFuture.andAllSucceed(removals, on: channel.eventLoop)
            .whenComplete { result in
                guard case .success = result else {
                    channel.close(promise: nil)
                    return
                }
                var ack = channel.allocator.buffer(capacity: 40)
                ack.writeString("HTTP/1.1 200 Connection Established\r\n\r\n")
                channel.writeAndFlush(NIOAny(ack)).whenComplete { _ in
                    MITMPipeline.installTLS(
                        channel: channel, host: host, port: port, sslContext: sslContext,
                        store: store, forwarder: forwarder
                    )
                        .whenComplete { result in
                            switch result {
                            case .success:
                                _ = channel.setOption(ChannelOptions.autoRead, value: true)
                                channel.read()
                            case .failure:
                                channel.close(promise: nil)
                            }
                        }
                }
            }
    }

    // MARK: - CONNECT (blind HTTPS pass-through)

    private func openTunnel(context: ChannelHandlerContext, host: String, port: Int) {
        let clientChannel = context.channel
        let startedAt = Date()

        // Pin the upstream connection to the client channel's event loop so both
        // ends of the glued tunnel share one loop — `GlueHandler` relays by writing
        // to the partner's context, which NIO requires happen on that loop.
        ClientBootstrap(group: clientChannel.eventLoop)
            .connect(host: host, port: port)
            .whenComplete { result in
                switch result {
                case let .success(upstream):
                    if self.observeTunnels {
                        TunnelFlow.record(host: host, port: port, startedAt: startedAt, store: self.store)
                    }
                    self.spliceRawBytes(client: clientChannel, upstream: upstream)
                case .failure:
                    clientChannel.close(promise: nil)
                }
            }
    }

    private func spliceRawBytes(client: Channel, upstream: Channel) {
        // Strip HTTP framing, glue the raw byte streams, then acknowledge the
        // CONNECT. The ack is written as raw bytes (not via HTTPResponseEncoder):
        // the encoder would chunk-frame a bodyless 200 and inject `0\r\n\r\n` into
        // the tunnel, corrupting the client's first TLS record.
        let removals = ["loom.http.encoder", "loom.http.decoder", "loom.proxy"].map { name in
            client.pipeline.removeHandler(name: name).recover { _ in () }
        }
        EventLoopFuture.andAllSucceed(removals, on: client.eventLoop).flatMap {
            TunnelFlow.glue(client: client, upstream: upstream)
        }.whenComplete { result in
            switch result {
            case .success:
                var ack = client.allocator.buffer(capacity: 40)
                ack.writeString("HTTP/1.1 200 Connection Established\r\n\r\n")
                client.writeAndFlush(NIOAny(ack), promise: nil)
            case .failure:
                client.close(promise: nil)
                upstream.close(promise: nil)
            }
        }
    }
}
