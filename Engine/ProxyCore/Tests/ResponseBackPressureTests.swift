import Foundation
import Synchronization
import NIOCore
import NIOEmbedded
import NIOHTTP1
import NIOPosix
import Testing
@testable import LoomProxyCore
import LoomSharedModels

/// A client that stops reading must stop the origin, not fill Loom's memory.
///
/// The response leg had no back-pressure at either hop: the upstream socket read as
/// fast as the origin sent, into an unbounded stream, and `StreamRelay` wrote every
/// chunk to the client channel without waiting. Measured in Release: a 1 GB download
/// to a client reading at 200 MB/s peaked at **1055 MB** RSS — the whole response —
/// against **29 MB** with `UpstreamReadGate` and the relay's write budget in place.
///
/// The end-to-end test reads the bound off the *origin*: how much it managed to hand
/// to its socket while the client read nothing. Without back-pressure that is all of
/// it; with it, it is the gate, the relay's budget and the kernel's socket buffers.
/// Measured: the origin stalls at **3.2 MB** of 128, and at all 128 with the gate and
/// the budget opened up — so the 48 MB bound has room for a CI kernel's larger socket
/// buffers and none for the regression.
@Suite("Response back-pressure", .timeLimit(.minutes(1)))
struct ResponseBackPressureTests {
    private static let total = 128 << 20

    @Test func aClientThatStopsReadingStopsTheOrigin() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 2)
        defer { shutdownBlocking(group) }
        let sent = Counter()
        let origin = try await ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.pipeline.configureHTTPServerPipeline().flatMap {
                    channel.pipeline.addHandler(StreamingOrigin(total: Self.total, sent: sent))
                }
            }
            .bind(host: "127.0.0.1", port: 0).get()
        defer { origin.close(promise: nil) }

        let engine = ProxyEngine(persistFlows: false, capacity: 0)
        let port = try await engine.start(port: 0)

        let received = Counter()
        let client = try await ClientBootstrap(group: group)
            .channelOption(ChannelOptions.autoRead, value: false)
            .channelInitializer { $0.pipeline.addHandler(ByteCounter(received: received)) }
            .connect(host: "127.0.0.1", port: port).get()
        var request = client.allocator.buffer(capacity: 128)
        let originPort = origin.localAddress!.port!
        request.writeString("GET http://127.0.0.1:\(originPort)/big HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n")
        try await client.writeAndFlush(request).get()
        client.read() // one read, for the head; then the client goes quiet

        // Wait for the origin to stop making progress.
        var last = -1
        for _ in 0 ..< 100 {
            try await Task.sleep(for: .milliseconds(200))
            let now = sent.value
            if now == last || now >= Self.total { break }
            last = now
        }
        let stalledAt = sent.value
        #expect(
            stalledAt < 48 << 20,
            """
            The origin got \(stalledAt >> 20) MB of a \(Self.total >> 20) MB response out while \
            the client read nothing. That is Loom buffering the response instead of pacing the \
            origin — check `UpstreamReadGate` and `StreamRelay.clientWriteBudget`.
            """
        )

        // Then the client catches up, and every byte arrives: a gate that never
        // reopened would show up here as a stall, not as a pass above.
        try await client.setOption(ChannelOptions.autoRead, value: true).get()
        client.read()
        for _ in 0 ..< 200 where received.value < Self.total {
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(received.value >= Self.total, "the response must complete once the client reads")

        try await client.close().get()
        await engine.stopForTest()
    }

    @Test func theGateHoldsAReadPastItsWatermarkAndReleasesItOnConsumption() throws {
        let reads = Counter()
        let gate = UpstreamReadGate()
        let channel = EmbeddedChannel()
        try channel.pipeline.syncOperations.addHandlers([ReadCounter(reads: reads), gate])
        let generation = gate.begin()

        func body(_ bytes: Int) throws {
            try channel.writeInbound(HTTPClientResponsePart.body(channel.allocator.buffer(repeating: 0, count: bytes)))
        }
        try body(UpstreamReadGate.highWatermark - 1)
        channel.read()
        #expect(reads.value == 1, "under the watermark a read passes")

        try body(1)
        channel.read()
        #expect(reads.value == 1, "at the watermark the read is held")

        gate.consumed(UpstreamReadGate.highWatermark - UpstreamReadGate.lowWatermark - 1, generation: generation)
        #expect(reads.value == 1, "still above the low watermark")
        gate.consumed(1, generation: generation)
        #expect(reads.value == 2, "back at the low watermark the held read goes out")

        // A consumer of an earlier exchange cannot move a later one's count, and a
        // new exchange starts clean even if the last one left a read held.
        try body(UpstreamReadGate.highWatermark)
        channel.read()
        #expect(reads.value == 2)
        let next = gate.begin()
        #expect(reads.value == 3, "begin() releases a read the previous exchange left held")
        gate.consumed(1 << 30, generation: generation)
        try body(UpstreamReadGate.highWatermark)
        channel.read()
        #expect(reads.value == 3, "a stale generation's consumption is ignored")
        gate.consumed(UpstreamReadGate.highWatermark, generation: next)
        #expect(reads.value == 4)
        _ = try channel.finish()
    }
}

/// Streams `total` bytes as fast as its socket will take them, counting what was
/// actually handed to the kernel.
private final class StreamingOrigin: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private let total: Int
    private let sent: Counter
    private var queued = 0
    private var started = false

    init(total: Int, sent: Counter) {
        self.total = total
        self.sent = sent
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard case .end = unwrapInboundIn(data), !started, queued == 0 else { return }
        started = true
        var headers = HTTPHeaders()
        headers.add(name: "Content-Length", value: String(total))
        context.write(wrapOutboundOut(.head(HTTPResponseHead(version: .http1_1, status: .ok, headers: headers))), promise: nil)
        pump(context: context)
    }

    func channelWritabilityChanged(context: ChannelHandlerContext) {
        if context.channel.isWritable { pump(context: context) }
        context.fireChannelWritabilityChanged()
    }

    private func pump(context: ChannelHandlerContext) {
        let chunk = 64 << 10
        while started, queued < total, context.channel.isWritable {
            let size = min(chunk, total - queued)
            queued += size
            let promise = context.eventLoop.makePromise(of: Void.self)
            promise.futureResult.whenSuccess { [sent] in sent.add(size) }
            context.writeAndFlush(
                wrapOutboundOut(.body(.byteBuffer(context.channel.allocator.buffer(repeating: 0x61, count: size)))),
                promise: promise
            )
        }
        if started, queued >= total {
            // Once: a later writability change re-enters `pump`, and a second `.end`
            // is a protocol violation NIO traps on.
            started = false
            context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)
        }
    }
}

private final class ByteCounter: ChannelInboundHandler, Sendable {
    typealias InboundIn = ByteBuffer
    private let received: Counter
    init(received: Counter) { self.received = received }
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let bytes = unwrapInboundIn(data).readableBytes
        received.add(bytes)
    }
}

private final class ReadCounter: ChannelOutboundHandler, Sendable {
    typealias OutboundIn = Never
    private let reads: Counter
    init(reads: Counter) { self.reads = reads }
    func read(context: ChannelHandlerContext) {
        reads.add(1)
        context.read()
    }
}

private final class Counter: Sendable {
    private let state = Mutex(0)
    var value: Int { state.withLock { $0 } }
    func add(_ n: Int) { state.withLock { $0 += n } }
}
