import Foundation
import Synchronization
import NIOCore
import NIOPosix
import NIOHTTP1
import NIOHTTP2
import NIOSSL
import NIOTLS
import Testing
@testable import LoomProxyCore
import LoomSharedModels

/// An HTTP/2 client may split `cookie` into one field per cookie (RFC 9113 §8.2.3);
/// HTTP/1.1 takes exactly one (RFC 6265 §5.4). Forwarding the crumbs unjoined made
/// every origin read only the first one — a signed-in github.com came back logged
/// out, and signing in again failed 422, while the browser still held its cookies.
@Suite("Cookie crumbs", .timeLimit(.minutes(1)))
struct CookieCrumbTests {
    @Test func crumbsAreJoinedIntoOneField() {
        var headers = HTTPHeaders()
        headers.add(name: "host", value: "example.test")
        headers.add(name: "cookie", value: "a=1")
        headers.add(name: "cookie", value: "user_session=abc")
        headers.add(name: "accept", value: "*/*")
        headers.add(name: "cookie", value: "z=9")

        let out = HTTPUtil.coalesceCookieCrumbs(headers)
        #expect(out["cookie"] == ["a=1; user_session=abc; z=9"])
        // Everything else keeps its order, and the joined field sits where the first
        // crumb was.
        #expect(out.map(\.name) == ["host", "cookie", "accept"])
    }

    @Test func aCrumbsOwnTrailingSeparatorIsNotDoubled() {
        var headers = HTTPHeaders()
        headers.add(name: "Cookie", value: "a=1; ")
        headers.add(name: "cookie", value: "b=2")
        #expect(HTTPUtil.coalesceCookieCrumbs(headers)["Cookie"] == ["a=1; b=2"])
    }

    /// One cookie header (every HTTP/1.1 client, and an h2 client that didn't split)
    /// must come back byte-identical — including a value the join would have trimmed.
    @Test func aSingleCookieHeaderIsUntouched() {
        var headers = HTTPHeaders()
        headers.add(name: "cookie", value: "a=1; b=2")
        let out = HTTPUtil.coalesceCookieCrumbs(headers)
        #expect(out["cookie"] == ["a=1; b=2"])
        #expect(HTTPUtil.coalesceCookieCrumbs(HTTPHeaders()).isEmpty)
    }

    /// End to end over a real h2 connection: three crumbs in, one `Cookie` header at
    /// the forwarder — the shape that broke logged-in sites.
    @Test func h2CrumbsReachUpstreamAsOneCookieHeader() async throws {
        let forwarder = HeaderRecordingForwarder(status: 200, body: Data("ok".utf8))
        let engine = ProxyEngine(forwarder: forwarder, caStore: InMemoryCAStore())

        let port = try await engine.start(port: 0)
        await engine.setSSLScope(SSLScope(enabled: true, include: ["*"]))
        let caPEM = try String(contentsOf: try await engine.exportCACertificate())

        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer {
            shutdownBlocking(group)
        }

        var clientConfig = TLSConfiguration.makeClientConfiguration()
        clientConfig.trustRoots = .certificates([try NIOSSLCertificate(bytes: Array(caPEM.utf8), format: .pem)])
        clientConfig.applicationProtocols = ["h2"]
        let clientCtx = try NIOSSLContext(configuration: clientConfig)

        let connected = group.next().makePromise(of: Void.self)
        let sender = CookieConnectSender(connected: connected)
        let client = try await ClientBootstrap(group: group)
            .channelInitializer { $0.pipeline.addHandler(sender) }
            .connect(host: "127.0.0.1", port: port).get()
        defer { client.close(promise: nil) }

        try await connected.futureResult.get()
        try await client.pipeline.removeHandler(sender).get()

        let tls = try NIOSSLClientHandler(context: clientCtx, serverHostname: "example.test")
        try await client.pipeline.addHandler(tls, position: .first).get()
        let multiplexer = try await client.configureHTTP2Pipeline(mode: .client).get()

        let responded = group.next().makePromise(of: Int.self)
        multiplexer.createStreamChannel(promise: nil) { stream in
            stream.pipeline.addHandler(HTTP2FramePayloadToHTTP1ClientCodec(httpProtocol: .https)).flatMap {
                stream.pipeline.addHandler(CrumbedRequestHandler(promise: responded))
            }
        }
        #expect(try await responded.futureResult.get() == 200)

        let flow = try #require(await awaitFlow(from: engine) {
            $0.request.url.contains("example.test/needs-cookies") && $0.response != nil
        })
        let sent = forwarder.lastHeaders.filter { $0.name.lowercased() == "cookie" }
        #expect(sent.count == 1)
        #expect(sent.first?.value == "a=1; user_session=abc; z=9")
        // The captured flow must show what Loom actually sent, not the crumbs.
        #expect(flow.request.headers.filter { $0.name.lowercased() == "cookie" }.count == 1)
        // Terminal, at the end of the body rather than in a `defer`, for the
        // reason `EngineTeardown.swift` gives: a `defer` cannot await, and the
        // blocking bridge that let it try parks a cooperative-pool thread.
        await engine.stopForTest()
    }
}

/// Records the request headers it was handed; otherwise a fixed response.
private final class HeaderRecordingForwarder: UpstreamForwarding, Sendable {
    private let status: Int
    private let body: Data
    private let seen = Mutex<[HeaderPair]>([])

    var lastHeaders: [HeaderPair] { seen.withLock { $0 } }

    init(status: Int, body: Data) {
        self.status = status
        self.body = body
    }

    func forward(method: String, url: URL, headers: [HeaderPair], body: Data?) async throws -> ForwardResult {
        seen.withLock { $0 = headers }
        return ForwardResult(
            statusCode: status,
            headers: [HeaderPair(name: "Content-Type", value: "text/plain")],
            body: self.body
        )
    }
}

/// Opens the CONNECT tunnel the MITM path needs before TLS goes on.
private final class CookieConnectSender: ChannelInboundHandler, RemovableChannelHandler {
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

/// Sends the request the way Chrome does over h2: one `cookie` field per cookie.
private final class CrumbedRequestHandler: ChannelInboundHandler {
    typealias InboundIn = HTTPClientResponsePart
    typealias OutboundOut = HTTPClientRequestPart

    private let promise: EventLoopPromise<Int>
    private var status = 0

    init(promise: EventLoopPromise<Int>) { self.promise = promise }

    func channelActive(context: ChannelHandlerContext) {
        var headers = HTTPHeaders()
        headers.add(name: "host", value: "example.test")
        headers.add(name: "cookie", value: "a=1")
        headers.add(name: "cookie", value: "user_session=abc")
        headers.add(name: "cookie", value: "z=9")
        let head = HTTPRequestHead(version: .init(major: 1, minor: 1), method: .GET, uri: "/needs-cookies", headers: headers)
        context.write(wrapOutboundOut(.head(head)), promise: nil)
        context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case let .head(head): status = Int(head.status.code)
        case .body: break
        case .end: promise.succeed(status)
        }
    }
}
