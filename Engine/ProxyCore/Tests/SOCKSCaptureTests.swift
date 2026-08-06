import Foundation
import NIOCore
import NIOPosix
import NIOSSL
import Testing
@testable import LoomProxyCore
import LoomSharedModels

/// End-to-end proof of the SOCKS5 listener: a real client performs the handshake
/// and then speaks each of the three things a SOCKS connection can turn out to be
/// — cleartext HTTP, TLS, and opaque bytes — and each lands on the right path.
///
/// The point of the listener is the traffic the HTTP proxy port never sees, so
/// "did it capture" is the assertion that matters, not "did it connect".
@Suite("SOCKS5 capture", .timeLimit(.minutes(1)))
struct SOCKSCaptureTests {
    @Test func capturesCleartextHTTPOverSOCKS() throws {
        let responseBody = #"{"ok":true,"via":"loom-socks"}"#
        let forwarder = StubForwarder(status: 200, body: Data(responseBody.utf8))
        let engine = ProxyEngine(forwarder: forwarder, caStore: InMemoryCAStore())
        _ = try runBlocking { try await engine.start(port: 0, socksPort: 0) }
        defer { runBlockingVoid { await engine.shutdown() } }
        let socksPort = try #require(try runBlocking { await engine.status().socksPort })

        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownBlocking(group) }
        let loop = group.next()
        let ready = loop.makePromise(of: Void.self)
        let responded = loop.makePromise(of: String.self)

        let handshake = SOCKSHandshakeClient(host: "example.test", port: 80, ready: ready)
        let collector = ByteCollector(sentinel: responseBody, promise: responded)
        let client = try ClientBootstrap(group: group)
            .channelInitializer { $0.pipeline.addHandler(handshake) }
            .connect(host: "127.0.0.1", port: socksPort).wait()
        defer { try? client.close().wait() }

        try ready.futureResult.wait()
        try client.pipeline.removeHandler(handshake).wait()
        try client.pipeline.addHandler(collector).wait()

        var request = client.allocator.buffer(capacity: 128)
        request.writeString("GET /api/thing HTTP/1.1\r\nHost: example.test\r\nX-Loom-Test: socks\r\nConnection: close\r\n\r\n")
        client.writeAndFlush(request, promise: nil)

        let raw = try responded.futureResult.wait()
        #expect(raw.contains("200"))
        #expect(raw.contains(responseBody))

        let flow = try #require(awaitFlowBlocking(from: engine) {
            $0.request.url.contains("example.test/api/thing")
        })
        #expect(flow.request.method == "GET")
        #expect(flow.request.url == "http://example.test/api/thing", "cleartext must not be recorded as https")
        #expect(flow.request.headers.contains { $0.name.lowercased() == "x-loom-test" && $0.value == "socks" })
        #expect(forwarder.lastURL?.absoluteString == "http://example.test/api/thing",
                "the re-sent leg must stay cleartext too")
    }

    @Test func interceptsTLSOverSOCKS() throws {
        let responseBody = #"{"ok":true,"via":"loom-socks-mitm"}"#
        let forwarder = StubForwarder(status: 200, body: Data(responseBody.utf8))
        let engine = ProxyEngine(forwarder: forwarder, caStore: InMemoryCAStore())
        _ = try runBlocking { try await engine.start(port: 0, socksPort: 0) }
        runBlockingVoid { await engine.setSSLScope(SSLScope(enabled: true, include: ["*"])) }
        let caPEM = try runBlocking { try await engine.exportCACertificate() }
        let caText = try String(contentsOf: caPEM)
        defer { runBlockingVoid { await engine.shutdown() } }
        let socksPort = try #require(try runBlocking { await engine.status().socksPort })

        var clientConfig = TLSConfiguration.makeClientConfiguration()
        clientConfig.trustRoots = .certificates([try NIOSSLCertificate(bytes: Array(caText.utf8), format: .pem)])
        let clientCtx = try NIOSSLContext(configuration: clientConfig)

        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownBlocking(group) }
        let loop = group.next()
        let ready = loop.makePromise(of: Void.self)
        let responded = loop.makePromise(of: String.self)

        let handshake = SOCKSHandshakeClient(host: "example.test", port: 443, ready: ready)
        let collector = ByteCollector(sentinel: responseBody, promise: responded)
        let client = try ClientBootstrap(group: group)
            .channelInitializer { $0.pipeline.addHandler(handshake) }
            .connect(host: "127.0.0.1", port: socksPort).wait()
        defer { try? client.close().wait() }

        try ready.futureResult.wait()
        try client.pipeline.removeHandler(handshake).wait()
        let tls = try NIOSSLClientHandler(context: clientCtx, serverHostname: "example.test")
        try client.pipeline.addHandler(tls, position: .first).wait()
        try client.pipeline.addHandler(collector).wait()

        var request = client.allocator.buffer(capacity: 128)
        request.writeString("GET /secure HTTP/1.1\r\nHost: example.test\r\nConnection: close\r\n\r\n")
        client.writeAndFlush(request, promise: nil)

        let raw = try responded.futureResult.wait()
        #expect(raw.contains(responseBody), "the client should get the decrypted body back")

        // The body is the part that lands last, so wait for it rather than for the
        // flow: this is the assertion that started failing once CI stopped caching
        // build products.
        let flow = try #require(awaitFlowBlocking(from: engine) {
            $0.request.url.contains("example.test/secure") && $0.response?.body != nil
        })
        #expect(flow.request.url == "https://example.test/secure")
        #expect(flow.response?.body == Data(responseBody.utf8))
    }

    @Test func relaysOpaqueTCPAndRecordsItAsATunnel() throws {
        // Not HTTP, not TLS — the case the HTTP proxy port can only blind-tunnel and
        // Loom would otherwise never see at all.
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 2)
        defer { shutdownBlocking(group) }
        let echo = try ServerBootstrap(group: group)
            .childChannelInitializer { $0.pipeline.addHandler(EchoHandler()) }
            .bind(host: "127.0.0.1", port: 0).wait()
        defer { try? echo.close().wait() }
        let echoPort = try #require(echo.localAddress?.port)

        let engine = ProxyEngine(forwarder: StubForwarder(status: 200, body: Data()), caStore: InMemoryCAStore())
        _ = try runBlocking { try await engine.start(port: 0, observeTunnels: true, socksPort: 0) }
        defer { runBlockingVoid { await engine.shutdown() } }
        let socksPort = try #require(try runBlocking { await engine.status().socksPort })

        let loop = group.next()
        let ready = loop.makePromise(of: Void.self)
        let echoed = loop.makePromise(of: String.self)

        let handshake = SOCKSHandshakeClient(host: "127.0.0.1", port: echoPort, ready: ready)
        let collector = ByteCollector(sentinel: "pong-marker", promise: echoed)
        let client = try ClientBootstrap(group: group)
            .channelInitializer { $0.pipeline.addHandler(handshake) }
            .connect(host: "127.0.0.1", port: socksPort).wait()
        defer { try? client.close().wait() }

        try ready.futureResult.wait()
        try client.pipeline.removeHandler(handshake).wait()
        try client.pipeline.addHandler(collector).wait()

        // Leading NUL: nothing HTTP- or TLS-shaped, so it must be relayed verbatim.
        var payload = client.allocator.buffer(capacity: 32)
        payload.writeBytes([0x00, 0x01])
        payload.writeString("pong-marker")
        client.writeAndFlush(payload, promise: nil)

        let seen = try echoed.futureResult.wait()
        #expect(seen.contains("pong-marker"), "opaque bytes must round-trip untouched")

        #expect(
            awaitFlowBlocking(from: engine) {
                $0.request.method == "CONNECT" && $0.request.url.contains("127.0.0.1:\(echoPort)")
            } != nil,
            "an observed tunnel should be visible as activity even though it wasn't read"
        )
    }

    @Test func relaysAServerFirstProtocolThatNeverSpeaksFirst() throws {
        // SSH, SMTP, IMAP, MySQL, PostgreSQL: the *server* sends a banner before the
        // client says a word. Classifying from the client's first bytes deadlocks
        // those outright — the client waits for a banner, and Loom hasn't opened the
        // upstream connection because it is still waiting to classify. Shipped broken
        // and found with `nc -X 5` against a real SSH server; the opaque test above
        // missed it because its payload was client-first.
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 2)
        defer { shutdownBlocking(group) }
        let banner = "SSH-2.0-loom-test\r\n"
        let server = try ServerBootstrap(group: group)
            .childChannelInitializer { $0.pipeline.addHandler(BannerHandler(banner: banner)) }
            .bind(host: "127.0.0.1", port: 0).wait()
        defer { try? server.close().wait() }
        let bannerPort = try #require(server.localAddress?.port)

        let engine = ProxyEngine(forwarder: StubForwarder(status: 200, body: Data()), caStore: InMemoryCAStore())
        _ = try runBlocking { try await engine.start(port: 0, socksPort: 0) }
        defer { runBlockingVoid { await engine.shutdown() } }
        let socksPort = try #require(try runBlocking { await engine.status().socksPort })

        let loop = group.next()
        let ready = loop.makePromise(of: Void.self)
        let received = loop.makePromise(of: String.self)

        let handshake = SOCKSHandshakeClient(host: "127.0.0.1", port: bannerPort, ready: ready)
        let collector = ByteCollector(sentinel: "loom-test", promise: received)
        let client = try ClientBootstrap(group: group)
            .channelInitializer { $0.pipeline.addHandler(handshake) }
            .connect(host: "127.0.0.1", port: socksPort).wait()
        defer { try? client.close().wait() }

        try ready.futureResult.wait()
        try client.pipeline.removeHandler(handshake).wait()
        try client.pipeline.addHandler(collector).wait()

        // Deliberately writes nothing. The banner has to arrive on the strength of the
        // sniff deadline alone.
        #expect(try received.futureResult.wait().contains(banner.trimmingCharacters(in: .whitespacesAndNewlines)))
    }

    @Test func refusesUDPAssociateInsteadOfHanging() throws {
        // A QUIC-minded client asks for UDP. Loom is a TCP proxy: say so, so the
        // client falls back instead of waiting on a reply that never comes.
        let engine = ProxyEngine(forwarder: StubForwarder(status: 200, body: Data()), caStore: InMemoryCAStore())
        _ = try runBlocking { try await engine.start(port: 0, socksPort: 0) }
        defer { runBlockingVoid { await engine.shutdown() } }
        let socksPort = try #require(try runBlocking { await engine.status().socksPort })

        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownBlocking(group) }
        let refused = group.next().makePromise(of: [UInt8].self)

        let client = try ClientBootstrap(group: group)
            .channelInitializer { $0.pipeline.addHandler(RawSOCKSProbe(
                // Greeting, then UDP ASSOCIATE for 1.2.3.4:443.
                request: [5, 0x03, 0x00, 0x01, 1, 2, 3, 4, 0x01, 0xBB],
                reply: refused
            )) }
            .connect(host: "127.0.0.1", port: socksPort).wait()
        defer { try? client.close().wait() }

        let reply = try refused.futureResult.wait()
        #expect(reply.count >= 2)
        #expect(reply[1] == SOCKS5.Reply.commandNotSupported.rawValue)
    }

    /// The third answer to "why is nothing captured".
    ///
    /// A client that speaks HTTP to the SOCKS port (`curl -x 127.0.0.1:<socks>`)
    /// gets its connection accepted and immediately closed. Loom knows exactly what
    /// happened — the first byte was `G`, not a SOCKS5 greeting — but that only ever
    /// reached `os_log`, so over MCP an empty capture looked identical to a client
    /// that never ran. The refusal is now readable from `get_proxy_status`.
    @Test func aRefusedConnectionIsVisibleInTheStatus() throws {
        // No `reset()` and no exact count: `RefusalLog.shared` is process-wide and
        // this suite runs in parallel, so another test's refusal may land in the
        // same log. The assertion is about *this* refusal being findable, which is
        // the property under test; pinning a total would be pinning test ordering.
        let engine = ProxyEngine(forwarder: StubForwarder(status: 200, body: Data()), caStore: InMemoryCAStore())
        _ = try runBlocking { try await engine.start(port: 0, socksPort: 0) }
        defer { runBlockingVoid { await engine.shutdown() } }
        let socksPort = try #require(try runBlocking { await engine.status().socksPort })

        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownBlocking(group) }
        let closed = group.next().makePromise(of: [UInt8].self)
        let client = try ClientBootstrap(group: group)
            .channelInitializer {
                // "GET / HTTP/1.1" — an HTTP proxy request aimed at the SOCKS port.
                $0.pipeline.addHandler(RawSOCKSProbe(request: Array("GET / HTTP/1.1\r\n\r\n".utf8), reply: closed))
            }
            .connect(host: "127.0.0.1", port: socksPort).wait()
        defer { try? client.close().wait() }
        _ = try? closed.futureResult.wait()   // the server closes without replying

        // The status is polled: the refusal is recorded on the event loop handling
        // that connection, which races the assertion otherwise.
        var refusal: ConnectionRefusal?
        for _ in 0 ..< 100 where refusal == nil {
            let status = try runBlocking { await engine.status() }
            refusal = status.recentRefusals.first { $0.reason.contains("0x47") }
            if refusal == nil { usleep(20_000) }
        }
        let found = try #require(refusal, "the refusal never reached the status")
        #expect(found.listener == .socks)
        // The reason has to be actionable, not just present: this exact mistake is
        // fixed by aiming the client at the other port.
        #expect(found.reason.contains("HTTP proxy port"), "got \(found.reason)")
        #expect(found.peer?.contains("127.0.0.1") == true)
    }

    /// Bounded like every other in-memory collection in the engine, and honest
    /// about it: the tail is capped while the count keeps rising, so "this happened
    /// once" stays distinguishable from "this is happening to every request".
    @Test func refusalsAreBoundedButTheCountIsNot() {
        // Its own instance, not `.shared`: the bound is a property of the type, and
        // reaching for the singleton would make this test both depend on and
        // clobber whatever else is recording refusals in parallel.
        let log = RefusalLog()
        for index in 0 ..< (RefusalLog.capacity + 15) {
            log.record(ConnectionRefusal(listener: .socks, reason: "refusal \(index)"))
        }
        let snapshot = log.snapshot()
        #expect(snapshot.recent.count == RefusalLog.capacity)
        #expect(snapshot.total == RefusalLog.capacity + 15)
        #expect(snapshot.recent.first?.reason == "refusal \(RefusalLog.capacity + 14)", "newest first")
    }

    // MARK: - async → sync bridges

    private func runBlocking<T>(_ body: @escaping @Sendable () async throws -> T) throws -> T {
        let box = SOCKSResultBox<T>()
        let sem = DispatchSemaphore(value: 0)
        Task { await box.run(body); sem.signal() }
        sem.wait()
        return try box.take()
    }

    private func runBlockingVoid(_ body: @escaping @Sendable () async -> Void) {
        let sem = DispatchSemaphore(value: 0)
        Task { await body(); sem.signal() }
        sem.wait()
    }
}

private final class SOCKSResultBox<T>: @unchecked Sendable {
    private var value: Result<T, Error>?
    func run(_ body: () async throws -> T) async {
        do { value = .success(try await body()) } catch { value = .failure(error) }
    }
    func take() throws -> T { try value!.get() }
}

// MARK: - Test doubles

/// Performs the client half of a SOCKS5 no-auth `CONNECT`, fulfilling `ready` once
/// the server's success reply lands. Accumulates across reads on purpose: the
/// server is free to split its two replies however it likes.
private final class SOCKSHandshakeClient: ChannelInboundHandler, RemovableChannelHandler {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    private enum Step { case awaitingMethod, awaitingReply, done }

    private let host: String
    private let port: Int
    private let ready: EventLoopPromise<Void>
    private var step: Step = .awaitingMethod
    private var seen: [UInt8] = []

    init(host: String, port: Int, ready: EventLoopPromise<Void>) {
        self.host = host
        self.port = port
        self.ready = ready
    }

    func channelActive(context: ChannelHandlerContext) {
        var greeting = context.channel.allocator.buffer(capacity: 3)
        greeting.writeBytes([5, 1, 0x00])
        context.writeAndFlush(wrapOutboundOut(greeting), promise: nil)
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var buffer = unwrapInboundIn(data)
        if let bytes = buffer.readBytes(length: buffer.readableBytes) { seen.append(contentsOf: bytes) }

        if step == .awaitingMethod {
            guard seen.count >= 2 else { return }
            guard seen[0] == 5, seen[1] == 0x00 else {
                ready.fail(ProxyControlError.replayFailed("method selection rejected: \(seen)"))
                return
            }
            seen.removeFirst(2)
            step = .awaitingReply

            let hostBytes = Array(host.utf8)
            var request: [UInt8] = [5, 0x01, 0x00, 0x03, UInt8(hostBytes.count)]
            request.append(contentsOf: hostBytes)
            request.append(contentsOf: [UInt8(port >> 8), UInt8(port & 0xFF)])
            var out = context.channel.allocator.buffer(capacity: request.count)
            out.writeBytes(request)
            context.writeAndFlush(wrapOutboundOut(out), promise: nil)
        }

        if step == .awaitingReply {
            guard seen.count >= 10 else { return }
            guard seen[1] == SOCKS5.Reply.succeeded.rawValue else {
                ready.fail(ProxyControlError.replayFailed("CONNECT refused: \(seen)"))
                return
            }
            seen.removeFirst(10)
            step = .done
            ready.succeed(())
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        ready.fail(error)
    }
}

/// Sends a greeting, then one raw request, and hands back the server's reply bytes
/// — for the paths where the reply *is* the assertion.
private final class RawSOCKSProbe: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    private let request: [UInt8]
    private let reply: EventLoopPromise<[UInt8]>
    private var greeted = false
    private var seen: [UInt8] = []

    init(request: [UInt8], reply: EventLoopPromise<[UInt8]>) {
        self.request = request
        self.reply = reply
    }

    func channelActive(context: ChannelHandlerContext) {
        var greeting = context.channel.allocator.buffer(capacity: 3)
        greeting.writeBytes([5, 1, 0x00])
        context.writeAndFlush(wrapOutboundOut(greeting), promise: nil)
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var buffer = unwrapInboundIn(data)
        if let bytes = buffer.readBytes(length: buffer.readableBytes) { seen.append(contentsOf: bytes) }
        if !greeted, seen.count >= 2 {
            seen.removeFirst(2)
            greeted = true
            var out = context.channel.allocator.buffer(capacity: request.count)
            out.writeBytes(request)
            context.writeAndFlush(wrapOutboundOut(out), promise: nil)
        }
        if greeted, seen.count >= 2 { reply.succeed(seen) }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        reply.fail(error)
    }
}

/// Echoes every byte back — the opaque upstream.
private final class EchoHandler: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        context.writeAndFlush(data, promise: nil)
    }
}

/// Accumulates inbound bytes as text, fulfilling `promise` once `sentinel` appears.
private final class ByteCollector: ChannelInboundHandler {
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

/// Sends a banner the moment the connection opens and never reads — a server-first
/// protocol in miniature (SSH, SMTP, IMAP, MySQL all behave this way).
private final class BannerHandler: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    private let banner: String

    init(banner: String) {
        self.banner = banner
    }

    func channelActive(context: ChannelHandlerContext) {
        var buffer = context.channel.allocator.buffer(capacity: banner.utf8.count)
        buffer.writeString(banner)
        context.writeAndFlush(wrapOutboundOut(buffer), promise: nil)
    }
}
