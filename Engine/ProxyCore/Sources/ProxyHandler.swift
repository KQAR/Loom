import Foundation
import NIOCore
import NIOPosix
import NIOHTTP1
import NIOSSL
import SharedModels

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

    private var requestHead: HTTPRequestHead?
    private var bodyBuffer: ByteBuffer?
    private var connectHead: HTTPRequestHead?

    init(
        store: FlowStore,
        group: EventLoopGroup,
        forwarder: UpstreamForwarding,
        ca: CertificateAuthority?,
        config: InterceptionConfig
    ) {
        self.store = store
        self.group = group
        self.forwarder = forwarder
        self.ca = ca
        self.config = config
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case let .head(head):
            if head.method == .CONNECT {
                // Defer the pipeline surgery until `.end`, so the decoder has
                // finished emitting the CONNECT's HTTP parts before we swap it out.
                connectHead = head
            } else {
                requestHead = head
                bodyBuffer = context.channel.allocator.buffer(capacity: 0)
            }
        case var .body(chunk):
            bodyBuffer?.writeBuffer(&chunk)
        case .end:
            if let connectHead {
                self.connectHead = nil
                handleConnect(context: context, head: connectHead)
                return
            }
            guard let head = requestHead else { return }
            let body = bodyBuffer.flatMap { buf in
                buf.getBytes(at: buf.readerIndex, length: buf.readableBytes).map { Data($0) }
            }
            forward(channel: context.channel, head: head, body: body)
            requestHead = nil
            bodyBuffer = nil
        }
    }

    // MARK: - Plain HTTP forwarding

    private func forward(channel: Channel, head: HTTPRequestHead, body: Data?) {
        // Proxied requests carry an absolute URI in the request line.
        guard let url = URL(string: head.uri), url.scheme != nil else {
            HTTPUtil.writeResponse(channel: channel, status: 400, headers: [],
                                   body: Data("Loom: expected absolute request URI\n".utf8), keepAlive: false)
            return
        }

        let headers = HTTPUtil.headerPairs(head.headers)
        let capturedRequest = CapturedRequest(method: head.method.rawValue, url: head.uri, headers: headers, body: body)
        let flowID = UUID()
        let startedAt = Date()
        let store = self.store
        let forwarder = self.forwarder
        let keepAlive = head.isKeepAlive
        let method = head.method.rawValue
        let sourcePort = channel.remoteAddress?.port
        let proxyPort = channel.localAddress?.port

        Task {
            let sourceApp = ProcessResolver.resolve(sourcePort: sourcePort, proxyPort: proxyPort)
            await store.upsert(Flow(id: flowID, request: capturedRequest, startedAt: startedAt, sourceApp: sourceApp))
            do {
                let result = try await forwarder.forward(method: method, url: url, headers: headers, body: body)
                await store.upsert(Flow(
                    id: flowID,
                    request: capturedRequest,
                    response: CapturedResponse(statusCode: result.statusCode, headers: result.headers, body: result.body),
                    startedAt: startedAt,
                    completedAt: Date(),
                    sourceApp: sourceApp,
                    appliedRules: result.appliedRules.isEmpty ? nil : result.appliedRules
                ))
                HTTPUtil.writeResponse(channel: channel, status: result.statusCode,
                                       headers: result.headers, body: result.body, keepAlive: keepAlive)
            } catch {
                await store.upsert(Flow(
                    id: flowID,
                    request: capturedRequest,
                    startedAt: startedAt,
                    completedAt: Date(),
                    error: error.localizedDescription,
                    sourceApp: sourceApp
                ))
                HTTPUtil.writeResponse(channel: channel, status: 502, headers: [],
                                       body: Data("Loom upstream error: \(error.localizedDescription)\n".utf8), keepAlive: false)
            }
        }
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
            openTunnel(context: context, host: host, port: port) // fail open: don't break the site
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
        pipeline.removeHandler(name: "loom.http.decoder")
            .flatMap { pipeline.removeHandler(name: "loom.http.encoder") }
            .flatMap { pipeline.removeHandler(name: "loom.proxy") }
            .whenComplete { _ in
                var ack = channel.allocator.buffer(capacity: 40)
                ack.writeString("HTTP/1.1 200 Connection Established\r\n\r\n")
                channel.writeAndFlush(NIOAny(ack)).whenComplete { _ in
                    pipeline.addHandler(NIOSSLServerHandler(context: sslContext), name: "loom.tls", position: .first)
                        .flatMap {
                            pipeline.addHandlers([
                                HTTPResponseEncoder(),
                                ByteToMessageHandler(HTTPRequestDecoder(leftOverBytesStrategy: .forwardBytes)),
                                TLSInterceptHandler(host: host, port: port, store: store, forwarder: forwarder),
                            ])
                        }
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

        // Pin the upstream connection to the client channel's event loop so both
        // ends of the glued tunnel share one loop — `GlueHandler` relays by writing
        // to the partner's context, which NIO requires happen on that loop.
        ClientBootstrap(group: clientChannel.eventLoop)
            .connect(host: host, port: port)
            .whenComplete { result in
                switch result {
                case let .success(upstream):
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
        EventLoopFuture.andAllSucceed(removals, on: client.eventLoop).flatMap { () -> EventLoopFuture<Void> in
            let (clientGlue, upstreamGlue) = GlueHandler.matchedPair()
            return client.pipeline.addHandler(clientGlue).and(upstream.pipeline.addHandler(upstreamGlue)).map { _ in () }
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
