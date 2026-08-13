import Foundation
import NIOCore
import NIOPosix
import Synchronization
import Testing
@testable import LoomProxyCore
import LoomSharedModels

/// The sniff deadline decides *when to ask the other side*, never *what the tunnel
/// is carrying*. These are the cases where it used to answer the second question and
/// get it wrong.
///
/// Both were found against a real Android app: every request after the first burst
/// was invisible, while the app itself worked perfectly — because an unread relay
/// records no flow, so "Loom captured nothing" and "the client never ran" look
/// identical. Charles captured them, which is what ruled out the client.
///
/// Each test sleeps past the deadline on purpose. That is not a timing hack standing
/// in for a signal: the deadline firing *is* the thing under test, and there is no
/// other way to reach the branch.
@Suite("Sniff deadline", .timeLimit(.minutes(1)))
struct SniffDeadlineTests {
    /// Comfortably past `TunnelSniffHandler.sniffDeadline` (150 ms).
    private static let pastTheDeadline = Duration.milliseconds(400)

    @Test func anIdleTunnelIsStillCapturedWhenTheClientFinallySpeaks() async throws {
        // What OkHttp and Chrome do: CONNECT, take the ack, park the tunnel in a
        // connection pool, and send nothing until a request wants it seconds later.
        // The deadline used to declare that opaque and relay the whole connection
        // unread — every request on it, for its entire life.
        let responseBody = #"{"ok":true,"via":"loom-idle-tunnel"}"#
        let forwarder = StubForwarder(status: 200, body: Data(responseBody.utf8))
        let engine = ProxyEngine(forwarder: forwarder, caStore: InMemoryCAStore())
        let port = try await engine.start(port: 0)
        await engine.setSSLScope(SSLScope(enabled: true, include: ["*"]))

        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownBlocking(group) }
        let loop = group.next()
        let acked = loop.makePromise(of: Void.self)
        let responded = loop.makePromise(of: String.self)

        let connect = CONNECTAckHandler(
            request: "CONNECT example.test:8765 HTTP/1.1\r\nHost: example.test:8765\r\n\r\n",
            acked: acked
        )
        let client = try await ClientBootstrap(group: group)
            .channelInitializer { $0.pipeline.addHandler(connect) }
            .connect(host: "127.0.0.1", port: port).get()
        defer { client.close(promise: nil) }

        try await acked.futureResult.get()
        try await client.pipeline.removeHandler(connect).get()
        try await client.pipeline.addHandler(SniffTextCollector(sentinel: responseBody, promise: responded)).get()

        try await Task.sleep(for: Self.pastTheDeadline)

        var request = client.allocator.buffer(capacity: 128)
        request.writeString(
            "GET /late HTTP/1.1\r\nHost: example.test:8765\r\nX-Loom-Test: idle-tunnel\r\n\r\n"
        )
        client.writeAndFlush(request, promise: nil)

        #expect(try await responded.futureResult.get().contains(responseBody))
        let flow = try #require(await awaitFlow(from: engine) {
            $0.request.url.contains("example.test:8765/late")
        }, "a tunnel that went quiet past the deadline must still be classified when it speaks")
        #expect(flow.request.headers.contains { $0.name.lowercased() == "x-loom-test" && $0.value == "idle-tunnel" })
        await engine.stopForTest()
    }

    @Test func aPrefixSplitAcrossTheDeadlineIsStillCaptured() async throws {
        // The second half of the same defect, and the one that bites on a bad link:
        // the client *has* spoken, but only part of something recognisable. A lone
        // `0x16` or an unfinished method token is `.needMore` — incomplete, not
        // unreadable — and the deadline used to treat the two identically. Measured
        // on a real network, a ClientHello split across segments with the tail 400 ms
        // behind was blind-relayed.
        let responseBody = #"{"ok":true,"via":"loom-split-prefix"}"#
        let forwarder = StubForwarder(status: 200, body: Data(responseBody.utf8))
        let engine = ProxyEngine(forwarder: forwarder, caStore: InMemoryCAStore())
        let port = try await engine.start(port: 0)
        await engine.setSSLScope(SSLScope(enabled: true, include: ["*"]))

        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownBlocking(group) }
        let loop = group.next()
        let acked = loop.makePromise(of: Void.self)
        let responded = loop.makePromise(of: String.self)

        let connect = CONNECTAckHandler(
            request: "CONNECT example.test:8765 HTTP/1.1\r\nHost: example.test:8765\r\n\r\n",
            acked: acked
        )
        let client = try await ClientBootstrap(group: group)
            .channelInitializer { $0.pipeline.addHandler(connect) }
            .connect(host: "127.0.0.1", port: port).get()
        defer { client.close(promise: nil) }

        try await acked.futureResult.get()
        try await client.pipeline.removeHandler(connect).get()
        try await client.pipeline.addHandler(SniffTextCollector(sentinel: responseBody, promise: responded)).get()

        // `GE` classifies as `.needMore` — a method token that hasn't ended yet.
        var head = client.allocator.buffer(capacity: 2)
        head.writeString("GE")
        client.writeAndFlush(head, promise: nil)

        try await Task.sleep(for: Self.pastTheDeadline)

        var tail = client.allocator.buffer(capacity: 128)
        tail.writeString(
            "T /split HTTP/1.1\r\nHost: example.test:8765\r\nX-Loom-Test: split-prefix\r\n\r\n"
        )
        client.writeAndFlush(tail, promise: nil)

        #expect(try await responded.futureResult.get().contains(responseBody))
        let flow = try #require(await awaitFlow(from: engine) {
            $0.request.url.contains("example.test:8765/split")
        }, "an incomplete prefix is late, not unreadable — the deadline must not resolve it")
        #expect(flow.request.method == "GET", "the two halves must reassemble into one request line")
        await engine.stopForTest()
    }

    @Test func anUnreachableOriginIsNotAVerdictOnTheTunnel() async throws {
        // The probe is evidence-gathering, not a decision: if it can't connect, the
        // client may still be about to send a ClientHello, and the real connection
        // made for it reports its own failure. Port 1 on loopback refuses instantly,
        // so this reaches the branch deterministically rather than via a DNS timeout.
        let responseBody = #"{"ok":true,"via":"loom-probe-refused"}"#
        let forwarder = StubForwarder(status: 200, body: Data(responseBody.utf8))
        let engine = ProxyEngine(forwarder: forwarder, caStore: InMemoryCAStore())
        let port = try await engine.start(port: 0)
        await engine.setSSLScope(SSLScope(enabled: true, include: ["*"]))

        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownBlocking(group) }
        let loop = group.next()
        let acked = loop.makePromise(of: Void.self)
        let responded = loop.makePromise(of: String.self)

        let connect = CONNECTAckHandler(
            request: "CONNECT 127.0.0.1:1 HTTP/1.1\r\nHost: 127.0.0.1:1\r\n\r\n",
            acked: acked
        )
        let client = try await ClientBootstrap(group: group)
            .channelInitializer { $0.pipeline.addHandler(connect) }
            .connect(host: "127.0.0.1", port: port).get()
        defer { client.close(promise: nil) }

        try await acked.futureResult.get()
        try await client.pipeline.removeHandler(connect).get()
        try await client.pipeline.addHandler(SniffTextCollector(sentinel: responseBody, promise: responded)).get()

        try await Task.sleep(for: Self.pastTheDeadline)

        var request = client.allocator.buffer(capacity: 128)
        request.writeString("GET /after-refusal HTTP/1.1\r\nHost: 127.0.0.1:1\r\n\r\n")
        client.writeAndFlush(request, promise: nil)

        #expect(try await responded.futureResult.get().contains(responseBody))
        _ = try #require(await awaitFlow(from: engine) {
            $0.request.url.contains("127.0.0.1:1/after-refusal")
        }, "a probe that could not connect must not decide the tunnel is opaque")
        await engine.stopForTest()
    }

    @Test func serverFirstStillWorks_andTheClientsEarlierBytesReachTheServer() async throws {
        // The case the deadline exists for, now reached through the probe rather than
        // through a guess — plus the ordering the probe path has to get right. The
        // client says something incomplete first (`HELO` with no space is a
        // `.needMore` token), the server greets, and both halves must survive: the
        // banner reaches the client, and the bytes the client already sent reach the
        // server *before* anything it says next.
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 2)
        defer { shutdownBlocking(group) }
        let banner = "220 loom-probe-banner ready\r\n"
        let heard = SpokenBytes()
        let server = try await ServerBootstrap(group: group)
            .childChannelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.addHandler(
                        BannerThenRecord(banner: banner, heard: heard)
                    )
                }
            }
            .bind(host: "127.0.0.1", port: 0).get()
        defer { server.close(promise: nil) }
        let bannerPort = try #require(server.localAddress?.port)

        let engine = ProxyEngine(forwarder: StubForwarder(status: 200, body: Data()), caStore: InMemoryCAStore())
        let port = try await engine.start(port: 0)
        await engine.setSSLScope(SSLScope(enabled: true, include: ["*"]))

        let loop = group.next()
        let acked = loop.makePromise(of: Void.self)
        let received = loop.makePromise(of: String.self)

        let connect = CONNECTAckHandler(
            request: "CONNECT 127.0.0.1:\(bannerPort) HTTP/1.1\r\nHost: 127.0.0.1:\(bannerPort)\r\n\r\n",
            acked: acked
        )
        let client = try await ClientBootstrap(group: group)
            .channelInitializer { $0.pipeline.addHandler(connect) }
            .connect(host: "127.0.0.1", port: port).get()
        defer { client.close(promise: nil) }

        try await acked.futureResult.get()
        try await client.pipeline.removeHandler(connect).get()
        try await client.pipeline.addHandler(SniffTextCollector(sentinel: "loom-probe-banner", promise: received)).get()

        var early = client.allocator.buffer(capacity: 4)
        early.writeString("HELO")
        client.writeAndFlush(early, promise: nil)

        #expect(try await received.futureResult.get().contains(banner.trimmingCharacters(in: .whitespacesAndNewlines)))
        try await heard.waitFor("HELO")
        await engine.stopForTest()
    }

    @Test func anIdleTunnelOverSOCKSIsStillCaptured() async throws {
        // Both entry points install the same sniffer, so the fix has to hold on the
        // SOCKS side too — and a SOCKS client is *more* likely to hit this, since the
        // success reply goes out before the client has any reason to speak.
        let responseBody = #"{"ok":true,"via":"loom-socks-idle"}"#
        let forwarder = StubForwarder(status: 200, body: Data(responseBody.utf8))
        let engine = ProxyEngine(forwarder: forwarder, caStore: InMemoryCAStore())
        _ = try await engine.start(port: 0, socksPort: 0)
        let socksPort = try #require(await engine.status().socksPort)

        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownBlocking(group) }
        let loop = group.next()
        let ready = loop.makePromise(of: Void.self)
        let responded = loop.makePromise(of: String.self)

        let handshake = SOCKSHandshakeClient(host: "example.test", port: 80, ready: ready)
        let client = try await ClientBootstrap(group: group)
            .channelInitializer { $0.pipeline.addHandler(handshake) }
            .connect(host: "127.0.0.1", port: socksPort).get()
        defer { client.close(promise: nil) }

        try await ready.futureResult.get()
        try await client.pipeline.removeHandler(handshake).get()
        try await client.pipeline.addHandler(SniffTextCollector(sentinel: responseBody, promise: responded)).get()

        try await Task.sleep(for: Self.pastTheDeadline)

        var request = client.allocator.buffer(capacity: 128)
        request.writeString("GET /socks-late HTTP/1.1\r\nHost: example.test\r\nConnection: close\r\n\r\n")
        client.writeAndFlush(request, promise: nil)

        #expect(try await responded.futureResult.get().contains(responseBody))
        _ = try #require(await awaitFlow(from: engine) {
            $0.request.url.contains("example.test/socks-late")
        }, "an idle SOCKS tunnel must be classified when its client finally speaks")
        await engine.stopForTest()
    }
}

// MARK: - Test doubles

/// Accumulates inbound text until it contains `sentinel`, then fulfils the promise.
/// A local copy of the collector the CONNECT suite uses, which is file-private there.
private final class SniffTextCollector: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer

    private let sentinel: String
    private let promise: EventLoopPromise<String>
    private var seen = ""

    init(sentinel: String, promise: EventLoopPromise<String>) {
        self.sentinel = sentinel
        self.promise = promise
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var buffer = unwrapInboundIn(data)
        seen += buffer.readString(length: buffer.readableBytes) ?? ""
        if seen.contains(sentinel) { promise.succeed(seen) }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        promise.fail(error)
        context.close(promise: nil)
    }
}

/// What a server-first origin heard from its client, readable from the test's task.
final class SpokenBytes: Sendable {
    private let text = Mutex("")

    func append(_ chunk: String) { text.withLock { $0 += chunk } }
    var value: String { text.withLock { $0 } }

    /// Poll until `needle` shows up. The write travels client → Loom → glue →
    /// server after the splice completes, so there is no promise on this side to
    /// await; the bound is what turns a lost byte into a failure rather than a hang.
    func waitFor(_ needle: String, timeout: Duration = .seconds(5)) async throws {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if value.contains(needle) { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        Issue.record("server never received \(needle); heard \"\(value)\" instead")
    }
}

/// Greets on connect like SMTP/SSH, and records everything the client sends.
private final class BannerThenRecord: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    private let banner: String
    private let heard: SpokenBytes

    init(banner: String, heard: SpokenBytes) {
        self.banner = banner
        self.heard = heard
    }

    func channelActive(context: ChannelHandlerContext) {
        var buffer = context.channel.allocator.buffer(capacity: banner.utf8.count)
        buffer.writeString(banner)
        context.writeAndFlush(wrapOutboundOut(buffer), promise: nil)
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var buffer = unwrapInboundIn(data)
        heard.append(buffer.readString(length: buffer.readableBytes) ?? "")
    }
}
