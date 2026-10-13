import Foundation
import Synchronization
import NIOCore
import NIOHTTP1
import NIOPosix
import Testing
@testable import LoomProxyCore
import LoomSharedModels

/// The blind CONNECT tunnel — with an empty SSL whitelist, every HTTPS origin — must
/// pace the origin on the client and must not drop what it has already relayed.
///
/// `GlueHandler` did neither. Measured in Release, a 1 GB download through a tunnel
/// to a client reading at 200 MB/s peaked at **1026 MB** RSS, and the client got
/// **35 MB** of it: the origin finished, closed, and the close threw away everything
/// still queued for the client.
///
/// The origin here is plain HTTP on purpose. The engine does not sniff a tunnel to a
/// host outside the SSL scope — it splices bytes — so what travels inside is
/// irrelevant to the code under test, and plaintext lets the test count body bytes.
@Suite("Tunnel back-pressure", .timeLimit(.minutes(1)))
struct TunnelBackPressureTests {
    private static let total = 128 << 20

    @Test func aClientThatStopsReadingStopsTheOriginThroughATunnel() async throws {
        let rig = try await TunnelRig(total: Self.total, closeWhenDone: false)
        defer { rig.shutdown() }
        try await rig.connectAndRequest()

        let stalledAt = try await rig.originStalls()
        #expect(
            stalledAt < 48 << 20,
            """
            The origin got \(stalledAt >> 20) MB of a \(Self.total >> 20) MB response through \
            the tunnel while the client read nothing — `GlueHandler` is relaying without \
            back-pressure again.
            """
        )

        try await rig.client.setOption(ChannelOptions.autoRead, value: true).get()
        rig.client.read()
        #expect(try await rig.bodyBytesReceived(atLeast: Self.total) >= Self.total)
        await rig.stop()
    }

    @Test func anOriginThatClosesRightAfterSendingLosesNothing() async throws {
        let total = 32 << 20
        let rig = try await TunnelRig(total: total, closeWhenDone: true)
        defer { rig.shutdown() }
        try await rig.connectAndRequest()

        // A slow reader: one read every few milliseconds, so the origin finishes and
        // closes while Loom still holds bytes for the client.
        let reading = Task {
            while !Task.isCancelled {
                rig.client.read()
                try? await Task.sleep(for: .milliseconds(2))
            }
        }
        defer { reading.cancel() }

        let received = try await rig.bodyBytesReceived(atLeast: total)
        #expect(
            received == total,
            """
            The client got \(received) of \(total) body bytes. The origin closed after its \
            last write, and closing the client side before its queued writes flushed \
            dropped the tail.
            """
        )
        await rig.stop()
    }
}

/// An origin, the engine with its default (empty) SSL scope, and a client whose reads
/// the test drives by hand.
private final class TunnelRig: Sendable {
    let group: MultiThreadedEventLoopGroup
    let sent: Counter
    let collector: ResponseCollector
    let origin: Channel
    let engine: ProxyEngine
    let client: Channel

    init(total: Int, closeWhenDone: Bool) async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 2)
        let sent = Counter()
        let collector = ResponseCollector()
        self.group = group
        self.sent = sent
        self.collector = collector
        origin = try await ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.pipeline.configureHTTPServerPipeline().flatMap {
                    channel.pipeline.addHandler(StreamingOrigin(total: total, sent: sent, closeWhenDone: closeWhenDone))
                }
            }
            .bind(host: "127.0.0.1", port: 0).get()
        engine = ProxyEngine(persistFlows: false, capacity: 0)
        let port = try await engine.start(port: 0)
        client = try await ClientBootstrap(group: group)
            .channelOption(ChannelOptions.autoRead, value: false)
            .channelInitializer { $0.pipeline.addHandler(collector) }
            .connect(host: "127.0.0.1", port: port).get()
    }

    /// CONNECT, wait for the ack, then the request inside the tunnel.
    func connectAndRequest() async throws {
        let target = "127.0.0.1:\(origin.localAddress!.port!)"
        var connect = client.allocator.buffer(capacity: 128)
        connect.writeString("CONNECT \(target) HTTP/1.1\r\nHost: \(target)\r\n\r\n")
        try await client.writeAndFlush(connect).get()
        for _ in 0 ..< 100 where collector.headerEnds < 1 {
            client.read()
            try await Task.sleep(for: .milliseconds(20))
        }
        var request = client.allocator.buffer(capacity: 128)
        request.writeString("GET /big HTTP/1.1\r\nHost: \(target)\r\n\r\n")
        try await client.writeAndFlush(request).get()
        client.read() // one read; the response head, at most
    }

    /// How much the origin had handed to its socket once it stopped making progress.
    func originStalls() async throws -> Int {
        var last = -1
        for _ in 0 ..< 100 {
            try await Task.sleep(for: .milliseconds(200))
            let now = sent.value
            if now == last { break }
            last = now
        }
        return sent.value
    }

    /// Body bytes received, waiting up to ten seconds for `atLeast` — or for the
    /// count to stop moving, which is how a truncated response shows up.
    func bodyBytesReceived(atLeast expected: Int) async throws -> Int {
        var last = -1
        var still = 0
        for _ in 0 ..< 1000 {
            let now = collector.bodyBytes
            if now >= expected { return now }
            still = now == last ? still + 1 : 0
            if still >= 100 { return now } // a second without progress
            last = now
            try await Task.sleep(for: .milliseconds(10))
        }
        return collector.bodyBytes
    }

    func stop() async {
        try? await client.close().get()
        await engine.stopForTest()
        try? await origin.close().get()
    }

    func shutdown() { shutdownBlocking(group) }
}

/// Counts the response body bytes after two header blocks: the CONNECT ack, then the
/// origin's response head.
private final class ResponseCollector: ChannelInboundHandler, Sendable {
    typealias InboundIn = ByteBuffer

    private struct State {
        var total = 0
        var prefix: [UInt8] = []
        var bodyStart: Int?
        var headerEnds = 0
    }
    private let state = Mutex(State())

    var headerEnds: Int { state.withLock { $0.headerEnds } }
    var bodyBytes: Int { state.withLock { state in state.bodyStart.map { state.total - $0 } ?? 0 } }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let buffer = unwrapInboundIn(data)
        state.withLock { state in
            if state.bodyStart == nil {
                state.prefix += buffer.readableBytesView.prefix(16 << 10)
                state.headerEnds = 0
                var searchFrom = 0
                let crlf: [UInt8] = [13, 10, 13, 10]
                while let range = state.prefix[searchFrom...].firstRange(of: crlf) {
                    state.headerEnds += 1
                    searchFrom = range.upperBound
                    if state.headerEnds == 2 { state.bodyStart = range.upperBound; break }
                }
            }
            state.total += buffer.readableBytes
        }
    }
}
