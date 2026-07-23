import CFNetwork
import Foundation
import NIOCore
import NIOPosix
import NIOSSL
import XCTest
@testable import ProxyCore
import SharedModels

/// End-to-end proof that Loom decrypts HTTPS. A raw NIO client tunnels through
/// the proxy (CONNECT), speaks TLS trusting Loom's CA, and sends an HTTP request;
/// Loom terminates the TLS with a minted leaf, captures the plaintext exchange,
/// and answers via a stubbed upstream. Fully hermetic — no network, no origin.
final class HTTPSInterceptionTests: XCTestCase {
    func test_interceptsDecryptsAndCapturesHTTPS() throws {
        let responseBody = #"{"ok":true,"via":"loom-mitm"}"#
        let forwarder = StubForwarder(status: 200, body: Data(responseBody.utf8))
        let engine = ProxyEngine(forwarder: forwarder, caStore: InMemoryCAStore())

        let port = try runBlocking { try await engine.start(port: 0) }
        runBlockingVoid { await engine.setSSLScope(SSLScope(enabled: true, include: ["*"])) }
        let caPEM = try runBlocking { try await engine.exportCACertificate() }
        let caText = try String(contentsOf: caPEM)
        defer { runBlockingVoid { await engine.stop() } }

        // Client that trusts Loom's CA (as a machine would after install).
        var clientConfig = TLSConfiguration.makeClientConfiguration()
        clientConfig.trustRoots = .certificates([try NIOSSLCertificate(bytes: Array(caText.utf8), format: .pem)])
        let clientCtx = try NIOSSLContext(configuration: clientConfig)

        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { try? group.syncShutdownGracefully() }
        let loop = group.next()

        let connected = loop.makePromise(of: Void.self)
        let responded = loop.makePromise(of: String.self)
        let connectHandler = CONNECTHandler(
            request: "CONNECT example.test:443 HTTP/1.1\r\nHost: example.test:443\r\n\r\n",
            connected: connected
        )
        let collector = ResponseAccumulator(sentinel: responseBody, promise: responded)

        let client = try ClientBootstrap(group: group)
            .channelInitializer { $0.pipeline.addHandler(connectHandler) }
            .connect(host: "127.0.0.1", port: port).wait()
        defer { try? client.close().wait() }

        // 1. Wait for the proxy's CONNECT ack.
        try connected.futureResult.wait()

        // 2. Upgrade the client to TLS (trusting the CA) + a raw response collector.
        try client.pipeline.removeHandler(connectHandler).wait()
        let tls = try NIOSSLClientHandler(context: clientCtx, serverHostname: "example.test")
        try client.pipeline.addHandler(tls, position: .first).wait()
        try client.pipeline.addHandler(collector).wait()

        // 3. Send the HTTPS request; NIOSSL buffers it until the handshake finishes.
        var request = client.allocator.buffer(capacity: 128)
        request.writeString("GET /api/thing HTTP/1.1\r\nHost: example.test\r\nX-Loom-Test: loom-integration\r\nConnection: close\r\n\r\n")
        client.writeAndFlush(request, promise: nil)

        // 4. The decrypted response comes back through the MITM.
        let raw = try responded.futureResult.wait()
        XCTAssertTrue(raw.contains("200"), "client should receive a 200 status line")
        XCTAssertTrue(raw.contains(responseBody), "client should receive the decrypted body")

        // 5. The proxy captured the exchange in cleartext.
        let flows = try runBlocking { await engine.recentFlows(limit: 10) }
        let flow = try XCTUnwrap(flows.first { $0.request.url.contains("example.test/api/thing") })
        XCTAssertEqual(flow.request.method, "GET")
        XCTAssertTrue(flow.request.url.hasPrefix("https://"))
        XCTAssertTrue(
            flow.request.headers.contains { $0.name.lowercased() == "x-loom-test" && $0.value == "loom-integration" },
            "decrypted request headers should be captured"
        )
        XCTAssertEqual(flow.response?.statusCode, 200)
        XCTAssertEqual(flow.response?.body, Data(responseBody.utf8))
        XCTAssertEqual(forwarder.lastURL?.absoluteString, "https://example.test/api/thing")
    }

    func test_outOfScopeHostIsNotIntercepted() throws {
        // Interception off: a plain-HTTP request is still captured + forwarded
        // (sanity that the refactored forward path is intact).
        let forwarder = StubForwarder(status: 201, body: Data("created".utf8))
        let engine = ProxyEngine(forwarder: forwarder, caStore: InMemoryCAStore())
        let port = try runBlocking { try await engine.start(port: 0) }
        defer { runBlockingVoid { await engine.stop() } }

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.connectionProxyDictionary = [
            kCFNetworkProxiesHTTPEnable as String: 1,
            kCFNetworkProxiesHTTPProxy as String: "127.0.0.1",
            kCFNetworkProxiesHTTPPort as String: port,
        ]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }

        let (data, response) = try runBlocking { try await session.data(from: URL(string: "http://plain.test/create")!) }
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 201)
        XCTAssertEqual(data, Data("created".utf8))

        let flows = try runBlocking { await engine.recentFlows(limit: 10) }
        XCTAssertTrue(flows.contains { $0.request.url.contains("plain.test/create") })
    }

    func test_largeRequestBodyStreamsThroughProxyIntactAndIsCaptured() throws {
        // A large POST body must reach the upstream byte-for-byte via the streaming
        // request path, and be captured (under the cap) on the flow. Exercises the
        // full chain: handler bridge → RuleApplyingForwarder streaming passthrough →
        // the stub's default forwardStream (which collects the streamed body).
        let forwarder = StubForwarder(status: 200, body: Data("ok".utf8))
        let engine = ProxyEngine(forwarder: forwarder, caStore: InMemoryCAStore())
        let port = try runBlocking { try await engine.start(port: 0) }
        defer { runBlockingVoid { await engine.stop() } }

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
        let (data, response) = try runBlocking { try await session.data(for: request) }
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual(data, Data("ok".utf8))

        XCTAssertEqual(forwarder.lastBody, payload, "upstream must receive the full body byte-for-byte")

        let flows = try runBlocking { await engine.recentFlows(limit: 10) }
        let flow = try XCTUnwrap(flows.first { $0.request.url.contains("plain.test/upload") })
        XCTAssertEqual(flow.request.method, "POST")
        XCTAssertEqual(flow.request.body, payload, "the captured request body should match (2MB < cap)")
    }

    // MARK: - async → sync bridges (XCTest sync methods driving the actor)

    private func runBlocking<T>(_ body: @escaping () async throws -> T) throws -> T {
        let box = ResultBox<T>()
        let sem = DispatchSemaphore(value: 0)
        Task { await box.run(body); sem.signal() }
        sem.wait()
        return try box.take()
    }

    private func runBlockingVoid(_ body: @escaping () async -> Void) {
        let sem = DispatchSemaphore(value: 0)
        Task { await body(); sem.signal() }
        sem.wait()
    }
}

private final class ResultBox<T>: @unchecked Sendable {
    private var value: Result<T, Error>?
    func run(_ body: () async throws -> T) async { value = await Result { try await body() } }
    func take() throws -> T { try value!.get() }
}

private extension Result where Failure == Error {
    init(_ body: () async throws -> Success) async {
        do { self = .success(try await body()) } catch { self = .failure(error) }
    }
}

// MARK: - Test doubles

/// Deterministic upstream: records the URL it was asked to fetch, returns canned data.
final class StubForwarder: UpstreamForwarding, @unchecked Sendable {
    let status: Int
    let body: Data
    private let lock = NSLock()
    private var _lastURL: URL?
    private var _lastBody: Data?
    var lastURL: URL? { lock.lock(); defer { lock.unlock() }; return _lastURL }
    var lastBody: Data? { lock.lock(); defer { lock.unlock() }; return _lastBody }

    init(status: Int, body: Data) {
        self.status = status
        self.body = body
    }

    func forward(method: String, url: URL, headers: [HeaderPair], body: Data?) async throws -> ForwardResult {
        lock.lock(); _lastURL = url; _lastBody = body; lock.unlock()
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
