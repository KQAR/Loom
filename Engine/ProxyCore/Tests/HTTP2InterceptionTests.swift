import Foundation
import NIOCore
import NIOPosix
import NIOHTTP1
import NIOHTTP2
import NIOSSL
import Testing
@testable import ProxyCore
import SharedModels

/// End-to-end: an HTTP/2 client (ALPN "h2") through the MITM proxy is decrypted,
/// demuxed, forwarded, and captured — proving the ALPN branch + h2→h1 stream path.
@Suite struct HTTP2InterceptionTests {
    @Test func h2RequestIsDecryptedForwardedAndCaptured() async throws {
        let responseBody = #"{"via":"loom-h2"}"#
        let forwarder = StubForwarder(status: 200, body: Data(responseBody.utf8))
        let engine = ProxyEngine(forwarder: forwarder, caStore: InMemoryCAStore())

        let port = try await engine.start(port: 0)
        await engine.setSSLScope(SSLScope(enabled: true, include: ["*"]))
        let caURL = try await engine.exportCACertificate()
        let caPEM = try String(contentsOf: caURL)

        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer {
            try? group.syncShutdownGracefully()
            Task { await engine.stop() }
        }

        var clientConfig = TLSConfiguration.makeClientConfiguration()
        clientConfig.trustRoots = .certificates([try NIOSSLCertificate(bytes: Array(caPEM.utf8), format: .pem)])
        clientConfig.applicationProtocols = ["h2"]
        let clientCtx = try NIOSSLContext(configuration: clientConfig)

        let connected = group.next().makePromise(of: Void.self)
        let sender = ConnectSender(connected: connected)
        let client = try ClientBootstrap(group: group)
            .channelInitializer { $0.pipeline.addHandler(sender) }
            .connect(host: "127.0.0.1", port: port).wait()
        defer { try? client.close().wait() }

        try connected.futureResult.wait()
        try client.pipeline.removeHandler(sender).wait()

        let tls = try NIOSSLClientHandler(context: clientCtx, serverHostname: "example.test")
        try client.pipeline.addHandler(tls, position: .first).wait()
        let multiplexer = try client.configureHTTP2Pipeline(mode: .client).wait()

        let responded = group.next().makePromise(of: H2Response.self)
        multiplexer.createStreamChannel(promise: nil) { stream in
            stream.pipeline.addHandler(HTTP2FramePayloadToHTTP1ClientCodec(httpProtocol: .https)).flatMap {
                stream.pipeline.addHandler(H2RequestHandler(promise: responded))
            }
        }

        let response = try responded.futureResult.wait()
        #expect(response.status == 200)
        #expect(response.body == responseBody)

        let flows = try await engine.recentFlows(limit: 10)
        let flow = try #require(flows.first { $0.request.url.contains("example.test/h2/thing") })
        #expect(flow.request.method == "GET")
        #expect(flow.request.url.hasPrefix("https://"))
        #expect(flow.response?.statusCode == 200)
        #expect(forwarder.lastURL?.absoluteString == "https://example.test/h2/thing")
    }

    /// An h2 POST body (DATA frames, no Content-Length) must stream through and be
    /// captured. The payload is larger than the default 64 KiB flow-control window,
    /// so the client can only finish sending if the MITM side replenishes the window
    /// as our read()-driven bridge consumes it — proving h2 back-pressure works.
    @Test func h2RequestBodyStreamsThroughAndIsCaptured() async throws {
        let forwarder = StubForwarder(status: 200, body: Data("ok".utf8))
        let engine = ProxyEngine(forwarder: forwarder, caStore: InMemoryCAStore())

        let port = try await engine.start(port: 0)
        await engine.setSSLScope(SSLScope(enabled: true, include: ["*"]))
        let caPEM = try String(contentsOf: try await engine.exportCACertificate())

        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer {
            try? group.syncShutdownGracefully()
            Task { await engine.stop() }
        }

        var clientConfig = TLSConfiguration.makeClientConfiguration()
        clientConfig.trustRoots = .certificates([try NIOSSLCertificate(bytes: Array(caPEM.utf8), format: .pem)])
        clientConfig.applicationProtocols = ["h2"]
        let clientCtx = try NIOSSLContext(configuration: clientConfig)

        let connected = group.next().makePromise(of: Void.self)
        let sender = ConnectSender(connected: connected)
        let client = try ClientBootstrap(group: group)
            .channelInitializer { $0.pipeline.addHandler(sender) }
            .connect(host: "127.0.0.1", port: port).wait()
        defer { try? client.close().wait() }

        try connected.futureResult.wait()
        try client.pipeline.removeHandler(sender).wait()
        let tls = try NIOSSLClientHandler(context: clientCtx, serverHostname: "example.test")
        try client.pipeline.addHandler(tls, position: .first).wait()
        let multiplexer = try client.configureHTTP2Pipeline(mode: .client).wait()

        var payload = Data(count: 200_000) // > one h2 flow-control window
        for i in payload.indices { payload[i] = UInt8(i & 0xFF) }

        let responded = group.next().makePromise(of: H2Response.self)
        let payloadCopy = payload
        multiplexer.createStreamChannel(promise: nil) { stream in
            stream.pipeline.addHandler(HTTP2FramePayloadToHTTP1ClientCodec(httpProtocol: .https)).flatMap {
                stream.pipeline.addHandler(H2UploadHandler(payload: payloadCopy, promise: responded))
            }
        }

        let response = try responded.futureResult.wait()
        #expect(response.status == 200)

        #expect(forwarder.lastBody == payload, "the full h2 DATA body must reach upstream byte-for-byte")
        let flows = try await engine.recentFlows(limit: 10)
        let flow = try #require(flows.first { $0.request.url.contains("example.test/h2/upload") })
        #expect(flow.request.method == "POST")
        #expect(flow.request.body == payload, "the captured h2 request body should match (200KB < cap)")
    }
}

private struct H2Response { let status: Int; let body: String }

/// On an h2 stream: sends POST /h2/upload with a DATA body (no Content-Length),
/// collects the response status.
private final class H2UploadHandler: ChannelInboundHandler {
    typealias InboundIn = HTTPClientResponsePart
    typealias OutboundOut = HTTPClientRequestPart

    private let payload: Data
    private let promise: EventLoopPromise<H2Response>
    private var status = 0

    init(payload: Data, promise: EventLoopPromise<H2Response>) {
        self.payload = payload
        self.promise = promise
    }

    func channelActive(context: ChannelHandlerContext) {
        var headers = HTTPHeaders()
        headers.add(name: "host", value: "example.test")
        let head = HTTPRequestHead(version: .init(major: 1, minor: 1), method: .POST, uri: "/h2/upload", headers: headers)
        context.write(wrapOutboundOut(.head(head)), promise: nil)
        var buffer = context.channel.allocator.buffer(capacity: payload.count)
        buffer.writeBytes(payload)
        context.write(wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
        context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case let .head(head): status = Int(head.status.code)
        case .body: break
        case .end: promise.succeed(H2Response(status: status, body: ""))
        }
    }
}

/// Sends the CONNECT and signals once the proxy's 200 ack arrives.
private final class ConnectSender: ChannelInboundHandler, RemovableChannelHandler {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer
    private let connected: EventLoopPromise<Void>
    private var acked = false

    init(connected: EventLoopPromise<Void>) { self.connected = connected }

    func channelActive(context: ChannelHandlerContext) {
        var buffer = context.channel.allocator.buffer(capacity: 64)
        buffer.writeString("CONNECT example.test:443 HTTP/1.1\r\nHost: example.test:443\r\n\r\n")
        context.writeAndFlush(wrapOutboundOut(buffer), promise: nil)
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let buffer = unwrapInboundIn(data)
        if !acked, let text = buffer.getString(at: buffer.readerIndex, length: buffer.readableBytes), text.contains("200") {
            acked = true
            connected.succeed(())
        }
    }
}

/// On an h2 stream (h1-shaped via the codec): sends GET /h2/thing, collects the response.
private final class H2RequestHandler: ChannelInboundHandler {
    typealias InboundIn = HTTPClientResponsePart
    typealias OutboundOut = HTTPClientRequestPart

    private let promise: EventLoopPromise<H2Response>
    private var status = 0
    private var body = ""

    init(promise: EventLoopPromise<H2Response>) { self.promise = promise }

    func channelActive(context: ChannelHandlerContext) {
        var headers = HTTPHeaders()
        headers.add(name: "host", value: "example.test")
        let head = HTTPRequestHead(version: .init(major: 1, minor: 1), method: .GET, uri: "/h2/thing", headers: headers)
        context.write(wrapOutboundOut(.head(head)), promise: nil)
        context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case let .head(head): status = Int(head.status.code)
        case var .body(buffer): body += buffer.readString(length: buffer.readableBytes) ?? ""
        case .end: promise.succeed(H2Response(status: status, body: body))
        }
    }
}
