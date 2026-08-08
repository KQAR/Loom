import CFNetwork
import Foundation
import Synchronization
import NIOCore
import NIOPosix
import NIOSSL
import Testing
@testable import LoomProxyCore
import LoomSharedModels

/// End-to-end proof that Loom decrypts HTTPS. A raw NIO client tunnels through
/// the proxy (CONNECT), speaks TLS trusting Loom's CA, and sends an HTTP request;
/// Loom terminates the TLS with a minted leaf, captures the plaintext exchange,
/// and answers via a stubbed upstream. Fully hermetic — no network, no origin.
@Suite("HTTPS interception", .timeLimit(.minutes(1)))
struct HTTPSInterceptionTests {
    @Test func interceptsDecryptsAndCapturesHTTPS() async throws {
        let responseBody = #"{"ok":true,"via":"loom-mitm"}"#
        let forwarder = StubForwarder(status: 200, body: Data(responseBody.utf8))
        let engine = ProxyEngine(forwarder: forwarder, caStore: InMemoryCAStore())

        let port = try await engine.start(port: 0)
        await engine.setSSLScope(SSLScope(enabled: true, include: ["*"]))
        let caPEM = try await engine.exportCACertificate()
        let caText = try String(contentsOf: caPEM)

        // Client that trusts Loom's CA (as a machine would after install).
        var clientConfig = TLSConfiguration.makeClientConfiguration()
        clientConfig.trustRoots = .certificates([try NIOSSLCertificate(bytes: Array(caText.utf8), format: .pem)])
        let clientCtx = try NIOSSLContext(configuration: clientConfig)

        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownBlocking(group) }
        let loop = group.next()

        let connected = loop.makePromise(of: Void.self)
        let responded = loop.makePromise(of: String.self)
        let connectHandler = CONNECTHandler(
            request: "CONNECT example.test:443 HTTP/1.1\r\nHost: example.test:443\r\n\r\n",
            connected: connected
        )
        let collector = ResponseAccumulator(sentinel: responseBody, promise: responded)

        let client = try await ClientBootstrap(group: group)
            .channelInitializer { $0.pipeline.addHandler(connectHandler) }
            .connect(host: "127.0.0.1", port: port).get()
        defer { client.close(promise: nil) }

        // 1. Wait for the proxy's CONNECT ack.
        try await connected.futureResult.get()

        // 2. Upgrade the client to TLS (trusting the CA) + a raw response collector.
        try await client.pipeline.removeHandler(connectHandler).get()
        let tls = try NIOSSLClientHandler(context: clientCtx, serverHostname: "example.test")
        try await client.pipeline.addHandler(tls, position: .first).get()
        try await client.pipeline.addHandler(collector).get()

        // 3. Send the HTTPS request; NIOSSL buffers it until the handshake finishes.
        var request = client.allocator.buffer(capacity: 128)
        request.writeString("GET /api/thing HTTP/1.1\r\nHost: example.test\r\nX-Loom-Test: loom-integration\r\nConnection: close\r\n\r\n")
        client.writeAndFlush(request, promise: nil)

        // 4. The decrypted response comes back through the MITM.
        let raw = try await responded.futureResult.get()
        #expect(raw.contains("200"), "client should receive a 200 status line")
        #expect(raw.contains(responseBody), "client should receive the decrypted body")

        // 5. The proxy captured the exchange in cleartext.
        let flow = try #require(await awaitFlow(from: engine) {
            $0.request.url.contains("example.test/api/thing")
        })
        #expect(flow.request.method == "GET")
        #expect(flow.request.url.hasPrefix("https://"))
        #expect(
            flow.request.headers.contains { $0.name.lowercased() == "x-loom-test" && $0.value == "loom-integration" },
            "decrypted request headers should be captured"
        )
        #expect(flow.response?.statusCode == 200)
        #expect(flow.response?.body == Data(responseBody.utf8))
        #expect(forwarder.lastURL?.absoluteString == "https://example.test/api/thing")
        // Terminal, at the end of the body rather than in a `defer`, for the
        // reason `EngineTeardown.swift` gives: a `defer` cannot await, and the
        // blocking bridge that let it try parks a cooperative-pool thread.
        await engine.stopForTest()
    }

    @Test func outOfScopeHostIsNotIntercepted() async throws {
        // Interception off: a plain-HTTP request is still captured + forwarded
        // (sanity that the refactored forward path is intact).
        let forwarder = StubForwarder(status: 201, body: Data("created".utf8))
        let engine = ProxyEngine(forwarder: forwarder, caStore: InMemoryCAStore())
        let port = try await engine.start(port: 0)

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.connectionProxyDictionary = [
            kCFNetworkProxiesHTTPEnable as String: 1,
            kCFNetworkProxiesHTTPProxy as String: "127.0.0.1",
            kCFNetworkProxiesHTTPPort as String: port,
        ]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }

        let (data, response) = try await session.data(from: URL(string: "http://plain.test/create")!)
        #expect((response as? HTTPURLResponse)?.statusCode == 201)
        #expect(data == Data("created".utf8))

        let flows = await engine.recentFlows(limit: 10)
        #expect(flows.contains { $0.request.url.contains("plain.test/create") })
        // Terminal, at the end of the body rather than in a `defer`, for the
        // reason `EngineTeardown.swift` gives: a `defer` cannot await, and the
        // blocking bridge that let it try parks a cooperative-pool thread.
        await engine.stopForTest()
    }

    @Test func largeRequestBodyStreamsThroughProxyIntactAndIsCaptured() async throws {
        // A large POST body must reach the upstream byte-for-byte via the streaming
        // request path, and be captured (under the cap) on the flow. Exercises the
        // full chain: handler bridge → RuleApplyingForwarder streaming passthrough →
        // the stub's default forwardStream (which collects the streamed body).
        let forwarder = StubForwarder(status: 200, body: Data("ok".utf8))
        let engine = ProxyEngine(forwarder: forwarder, caStore: InMemoryCAStore())
        let port = try await engine.start(port: 0)

        // ~2 MB with a non-repeating pattern so a truncation/reorder bug can't hide.
        var payload = Data(count: 2_000_000)
        for i in payload.indices { payload[i] = UInt8(i & 0xFF) }

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        config.connectionProxyDictionary = [
            kCFNetworkProxiesHTTPEnable as String: 1,
            kCFNetworkProxiesHTTPProxy as String: "127.0.0.1",
            kCFNetworkProxiesHTTPPort as String: port,
        ]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }

        var request = URLRequest(url: URL(string: "http://plain.test/upload")!)
        request.httpMethod = "POST"
        request.httpBody = payload
        // Bound to a `let` before the bridge: the closure is `@Sendable`, and a captured
        // `var` is a shared mutable box regardless of whether anything writes to it.
        let outgoing = request
        let (data, response) = try await session.data(for: outgoing)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        #expect(data == Data("ok".utf8))

        #expect(forwarder.lastBody == payload, "upstream must receive the full body byte-for-byte")

        let flow = try #require(await awaitFlow(from: engine) {
            $0.request.url.contains("plain.test/upload") && $0.request.body != nil
        })
        #expect(flow.request.method == "POST")
        #expect(flow.request.body == payload, "the captured request body should match (2MB < cap)")
        // Terminal, at the end of the body rather than in a `defer`, for the
        // reason `EngineTeardown.swift` gives: a `defer` cannot await, and the
        // blocking bridge that let it try parks a cooperative-pool thread.
        await engine.stopForTest()
    }
}

// MARK: - Test doubles

/// Deterministic upstream: records the URL it was asked to fetch, returns canned data.
final class StubForwarder: UpstreamForwarding, Sendable {
    let status: Int
    let body: Data

    private struct Seen {
        var url: URL?
        var body: Data?
    }

    private let seen = Mutex(Seen())
    var lastURL: URL? { seen.withLock { $0.url } }
    var lastBody: Data? { seen.withLock { $0.body } }

    init(status: Int, body: Data) {
        self.status = status
        self.body = body
    }

    func forward(method: String, url: URL, headers: [HeaderPair], body: Data?) async throws -> ForwardResult {
        seen.withLock { $0.url = url; $0.body = body }
        return ForwardResult(
            statusCode: status,
            headers: [HeaderPair(name: "Content-Type", value: "application/json")],
            body: self.body
        )
    }
}

/// Sends a CONNECT on connect, fulfills `connected` once the `200` ack arrives.
private final class CONNECTHandler: ChannelInboundHandler, RemovableChannelHandler {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    private let request: String
    private let connected: EventLoopPromise<Void>
    private var seen = ""

    init(request: String, connected: EventLoopPromise<Void>) {
        self.request = request
        self.connected = connected
    }

    func channelActive(context: ChannelHandlerContext) {
        var buffer = context.channel.allocator.buffer(capacity: request.utf8.count)
        buffer.writeString(request)
        context.writeAndFlush(wrapOutboundOut(buffer), promise: nil)
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let buffer = unwrapInboundIn(data)
        seen += buffer.getString(at: buffer.readerIndex, length: buffer.readableBytes) ?? ""
        if seen.contains("\r\n\r\n") {
            if seen.contains(" 200 ") {
                connected.succeed(())
            } else {
                connected.fail(ProxyControlError.replayFailed("CONNECT not acked: \(seen)"))
            }
        }
    }
}

/// Accumulates decrypted response bytes, fulfilling `promise` once `sentinel` is seen.
private final class ResponseAccumulator: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer

    private let sentinel: String
    private let promise: EventLoopPromise<String>
    private var seen = ""

    init(sentinel: String, promise: EventLoopPromise<String>) {
        self.sentinel = sentinel
        self.promise = promise
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let buffer = unwrapInboundIn(data)
        seen += buffer.getString(at: buffer.readerIndex, length: buffer.readableBytes) ?? ""
        if seen.contains(sentinel) { promise.succeed(seen) }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        promise.fail(error)
    }
}
