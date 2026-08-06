import Foundation
import NIOCore
import NIOPosix
import Testing
@testable import LoomProxyCore
import LoomSharedModels

/// A `CONNECT` does not promise TLS, and Loom must not assume it does.
///
/// The case that made this a bug rather than a theory: a browser opens a `ws://`
/// URL by sending `CONNECT host:port` and then a **plaintext** upgrade request. With
/// the host in the SSL scope, Loom used to ack, install a TLS terminator and wait for
/// a ClientHello that never came — the handshake failed, the tunnel died, and the
/// request never reached the server at all. Nothing was captured, and the WebSocket
/// simply didn't work; excluding the host made it work but left it invisible, so
/// there was no setting where a browser's `ws://` was both delivered and captured.
///
/// Measured against real browsers on 8765: Chrome and Safari both send the CONNECT,
/// and the fixture server logged the upgrade only once the tunnel stopped being
/// treated as TLS.
@Suite("CONNECT tunnel sniffing", .timeLimit(.minutes(1)))
struct ConnectTunnelSniffTests {
    @Test func capturesACleartextRequestInsideAnInScopeCONNECT() throws {
        let responseBody = #"{"ok":true,"via":"loom-connect-cleartext"}"#
        let forwarder = StubForwarder(status: 200, body: Data(responseBody.utf8))
        let engine = ProxyEngine(forwarder: forwarder, caStore: InMemoryCAStore())
        let port = try runBlocking { try await engine.start(port: 0) }
        // In scope — the configuration under which this used to break. Out of scope
        // it was always blind-tunnelled and worked, which is why the failure looked
        // like "HTTPS interception breaks my dev server".
        runBlockingVoid { await engine.setSSLScope(SSLScope(enabled: true, include: ["*"])) }
        defer { runBlockingVoid { await engine.shutdown() } }

        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownBlocking(group) }
        let loop = group.next()
        let acked = loop.makePromise(of: Void.self)
        let responded = loop.makePromise(of: String.self)

        let connect = CONNECTAckHandler(
            request: "CONNECT example.test:8765 HTTP/1.1\r\nHost: example.test:8765\r\n\r\n",
            acked: acked
        )
        let client = try ClientBootstrap(group: group)
            .channelInitializer { $0.pipeline.addHandler(connect) }
            .connect(host: "127.0.0.1", port: port).wait()
        defer { try? client.close().wait() }

        try acked.futureResult.wait()
        try client.pipeline.removeHandler(connect).wait()
        try client.pipeline.addHandler(TextCollector(sentinel: responseBody, promise: responded)).wait()

        // Plain origin-form request, no TLS — the shape a browser sends inside a
        // `ws://` tunnel, and the shape the old code's TLS terminator swallowed.
        var request = client.allocator.buffer(capacity: 128)
        request.writeString(
            "GET /socket HTTP/1.1\r\nHost: example.test:8765\r\nX-Loom-Test: connect-cleartext\r\n\r\n"
        )
        client.writeAndFlush(request, promise: nil)

        // The client getting an answer at all is half the assertion: before the sniff,
        // this write vanished into a dead TLS handshake.
        let raw = try responded.futureResult.wait()
        #expect(raw.contains(responseBody))

        let flow = try #require(awaitFlowBlocking(from: engine) {
            $0.request.url.contains("example.test:8765/socket")
        })
        #expect(flow.request.url == "http://example.test:8765/socket",
                "a cleartext tunnel must not be recorded as https")
        #expect(
            flow.request.headers.contains { $0.name.lowercased() == "x-loom-test" && $0.value == "connect-cleartext" },
            "the request inside the tunnel is what the operator came to read"
        )
        #expect(forwarder.lastURL?.absoluteString == "http://example.test:8765/socket",
                "the re-sent leg must stay cleartext too")
    }

    @Test func capturesABrowserStyleWebSocketThroughCONNECT() throws {
        // The reported symptom, end to end: a real upgrade against a real server,
        // reached through a CONNECT whose host is in the SSL scope. The upgrade splice
        // connects upstream itself (no stub can stand in for it), so this needs a
        // listener that speaks the handshake and echoes frames.
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 2)
        defer { shutdownBlocking(group) }
        let server = try ServerBootstrap(group: group)
            .childChannelInitializer { $0.pipeline.addHandler(WebSocketEchoServer()) }
            .bind(host: "127.0.0.1", port: 0).wait()
        defer { try? server.close().wait() }
        let wsPort = try #require(server.localAddress?.port)

        let engine = ProxyEngine(forwarder: StubForwarder(status: 200, body: Data()), caStore: InMemoryCAStore())
        let port = try runBlocking { try await engine.start(port: 0) }
        runBlockingVoid { await engine.setSSLScope(SSLScope(enabled: true, include: ["*"])) }
        defer { runBlockingVoid { await engine.shutdown() } }

        let loop = group.next()
        let acked = loop.makePromise(of: Void.self)
        let echoed = loop.makePromise(of: String.self)

        let connect = CONNECTAckHandler(
            request: "CONNECT 127.0.0.1:\(wsPort) HTTP/1.1\r\nHost: 127.0.0.1:\(wsPort)\r\n\r\n",
            acked: acked
        )
        let client = try ClientBootstrap(group: group)
            .channelInitializer { $0.pipeline.addHandler(connect) }
            .connect(host: "127.0.0.1", port: port).wait()
        defer { try? client.close().wait() }

        try acked.futureResult.wait()
        try client.pipeline.removeHandler(connect).wait()
        try client.pipeline.addHandler(WebSocketProbe(promise: echoed)).wait()

        var upgrade = client.allocator.buffer(capacity: 256)
        upgrade.writeString(
            "GET /ws HTTP/1.1\r\nHost: 127.0.0.1:\(wsPort)\r\n"
                + "Upgrade: websocket\r\nConnection: Upgrade\r\n"
                + "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n\r\n"
        )
        client.writeAndFlush(upgrade, promise: nil)

        #expect(try echoed.futureResult.wait().contains("loom-ws-marker"),
                "the frame must round-trip — a killed tunnel is the bug this pins")

        // The frame is part of the wait, not an assertion after it: frames land on the
        // event loop after the client already has its echo, so a flow that merely
        // exists proves nothing yet (the reason `awaitFlow` takes a condition at all).
        let flow = try #require(awaitFlowBlocking(from: engine) { flow in
            flow.request.url.contains("127.0.0.1:\(wsPort)/ws")
                && flow.webSocketMessages?.contains(where: { $0.textPayload?.contains("loom-ws-marker") == true }) == true
        }, "the frames are the capture; a flow with none is just a tunnel")
        #expect(flow.response?.statusCode == 101)
        #expect(flow.request.url.hasPrefix("http://"),
                "an unencrypted upgrade must not be recorded as https — got \(flow.request.url)")
        #expect(flow.webSocketMessages?.contains { $0.direction == .clientToServer } == true)
    }

    @Test func relaysAServerFirstTunnelInsteadOfWaitingForATLSHandshake() throws {
        // SSH/SMTP/IMAP/MySQL through a CONNECT: the server speaks first, so there are
        // no client bytes to classify. Committing to TLS on the strength of the CONNECT
        // hung these forever — the client waited for a banner that Loom's TLS handler
        // was never going to let through. The sniff deadline is what releases them.
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 2)
        defer { shutdownBlocking(group) }
        let banner = "SSH-2.0-loom-connect-test\r\n"
        let server = try ServerBootstrap(group: group)
            .childChannelInitializer { $0.pipeline.addHandler(BannerOnConnect(banner: banner)) }
            .bind(host: "127.0.0.1", port: 0).wait()
        defer { try? server.close().wait() }
        let bannerPort = try #require(server.localAddress?.port)

        let engine = ProxyEngine(forwarder: StubForwarder(status: 200, body: Data()), caStore: InMemoryCAStore())
        let port = try runBlocking { try await engine.start(port: 0) }
        runBlockingVoid { await engine.setSSLScope(SSLScope(enabled: true, include: ["*"])) }
        defer { runBlockingVoid { await engine.shutdown() } }

        let loop = group.next()
        let acked = loop.makePromise(of: Void.self)
        let received = loop.makePromise(of: String.self)

        let connect = CONNECTAckHandler(
            request: "CONNECT 127.0.0.1:\(bannerPort) HTTP/1.1\r\nHost: 127.0.0.1:\(bannerPort)\r\n\r\n",
            acked: acked
        )
        let client = try ClientBootstrap(group: group)
            .channelInitializer { $0.pipeline.addHandler(connect) }
            .connect(host: "127.0.0.1", port: port).wait()
        defer { try? client.close().wait() }

        try acked.futureResult.wait()
        try client.pipeline.removeHandler(connect).wait()
        try client.pipeline.addHandler(TextCollector(sentinel: "loom-connect-test", promise: received)).wait()

        // Deliberately writes nothing: the banner has to arrive on the strength of the
        // deadline alone.
        #expect(try received.futureResult.wait().contains("SSH-2.0-loom-connect-test"))
    }
}

// MARK: - async → sync bridge

private func runBlocking<T>(_ body: @escaping @Sendable () async throws -> T) throws -> T {
    let box = ConnectSniffResultBox<T>()
    let semaphore = DispatchSemaphore(value: 0)
    Task { await box.run(body); semaphore.signal() }
    semaphore.wait()
    return try box.take()
}

private final class ConnectSniffResultBox<T>: @unchecked Sendable {
    private var value: Result<T, Error>?
    func run(_ body: () async throws -> T) async {
        do { value = .success(try await body()) } catch { value = .failure(error) }
    }
    func take() throws -> T { try value!.get() }
}

// MARK: - Test doubles

/// Sends one CONNECT on connect and fulfils `acked` when the proxy's
/// `200 Connection Established` lands. Accumulates across reads: the ack and the
/// first tunnel bytes can arrive in one packet or several.
private final class CONNECTAckHandler: ChannelInboundHandler, RemovableChannelHandler {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    private let request: String
    private let acked: EventLoopPromise<Void>
    private var seen = ""
    private var done = false

    init(request: String, acked: EventLoopPromise<Void>) {
        self.request = request
        self.acked = acked
    }

    func channelActive(context: ChannelHandlerContext) {
        var buffer = context.channel.allocator.buffer(capacity: request.utf8.count)
        buffer.writeString(request)
        context.writeAndFlush(wrapOutboundOut(buffer), promise: nil)
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let buffer = unwrapInboundIn(data)
        seen += buffer.getString(at: buffer.readerIndex, length: buffer.readableBytes) ?? ""
        guard !done, seen.contains("200") else { return }
        done = true
        acked.succeed(())
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        acked.fail(error)
    }
}

/// Accumulates inbound bytes as text, fulfilling `promise` once `sentinel` appears.
private final class TextCollector: ChannelInboundHandler {
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

/// Completes the WebSocket handshake (the accept value is RFC 6455's own example for
/// the key the test sends) and then echoes every frame byte back untouched.
private final class WebSocketEchoServer: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    private var upgraded = false
    private var seen = ""

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let buffer = unwrapInboundIn(data)
        guard !upgraded else {
            context.writeAndFlush(data, promise: nil)
            return
        }
        seen += buffer.getString(at: buffer.readerIndex, length: buffer.readableBytes) ?? ""
        guard seen.contains("\r\n\r\n") else { return }
        upgraded = true
        var reply = context.channel.allocator.buffer(capacity: 160)
        reply.writeString(
            "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
                + "Sec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=\r\n\r\n"
        )
        context.writeAndFlush(wrapOutboundOut(reply), promise: nil)
    }
}

/// Waits for the 101, sends one masked text frame, and fulfils `promise` with the
/// echoed payload — so a tunnel that dies mid-upgrade fails as a timeout rather than
/// as a passing test that proved nothing.
private final class WebSocketProbe: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    private let promise: EventLoopPromise<String>
    private var upgraded = false
    private var seen = ""

    init(promise: EventLoopPromise<String>) {
        self.promise = promise
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var buffer = unwrapInboundIn(data)
        if !upgraded {
            seen += buffer.getString(at: buffer.readerIndex, length: buffer.readableBytes) ?? ""
            guard seen.contains("101") , seen.contains("\r\n\r\n") else { return }
            upgraded = true
            let payload = Array("loom-ws-marker".utf8)
            let mask: [UInt8] = [0x01, 0x02, 0x03, 0x04]
            var frame: [UInt8] = [0x81, 0x80 | UInt8(payload.count)]
            frame.append(contentsOf: mask)
            frame.append(contentsOf: payload.enumerated().map { $0.element ^ mask[$0.offset % 4] })
            var out = context.channel.allocator.buffer(capacity: frame.count)
            out.writeBytes(frame)
            context.writeAndFlush(wrapOutboundOut(out), promise: nil)
            return
        }
        // Echoed frame: the payload comes back masked exactly as it went out, so
        // unmask with the same key rather than assuming the server rewrote it.
        guard let bytes = buffer.readBytes(length: buffer.readableBytes), bytes.count > 6 else { return }
        let mask = Array(bytes[2 ..< 6])
        let body = bytes[6...].enumerated().map { $0.element ^ mask[$0.offset % 4] }
        promise.succeed(String(decoding: body, as: UTF8.self))
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        promise.fail(error)
    }
}

/// Sends a banner the moment the connection opens and never reads — a server-first
/// protocol in miniature.
private final class BannerOnConnect: ChannelInboundHandler {
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
