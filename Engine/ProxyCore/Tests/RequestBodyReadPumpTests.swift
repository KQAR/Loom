import Testing
import Foundation
import NIOCore
import NIOEmbedded
import NIOPosix
import NIOHTTP1
@testable import LoomProxyCore
import LoomSharedModels

/// The request-body read pump, which is what makes a streamed upload progress at all:
/// each chunk the consumer has room for pulls the next `channel.read()`, so a body
/// larger than the watermark keeps moving without anything else nudging it, and a torn
/// down consumer stops the reads instead of pulling bytes nobody waits for.
///
/// Written while chasing an intermittent 60 s hang of
/// `HTTP2InterceptionTests.h2RequestBodyStreamsThroughAndIsCaptured` on a contended CI
/// runner (never reproduced locally, including under deliberate CPU load). The hang's
/// cause is still unknown, but the pump had no direct coverage at all — every test of it
/// went through real sockets, TLS and h2, where a stall says nothing about which link
/// broke. These run on an `EmbeddedChannel`, so a pump regression fails here with a
/// specific expectation rather than as a socket suite that stops.
///
/// One thing the chase did establish, worth keeping in mind before touching this code:
/// on an HTTP/2 stream channel `read()` can deliver already-buffered frames
/// **synchronously**, re-entering `channelRead`. A read issued before the current chunk
/// has been yielded therefore reorders the body — a corrupted upload, not a stall. The
/// yield-then-read order in the handlers is load-bearing.
@Suite struct RequestBodyReadPumpTests {
    /// Counts `read()` calls travelling down the pipeline.
    private final class ReadCounter: ChannelOutboundHandler {
        typealias OutboundIn = Never
        private(set) var reads = 0
        func read(context: ChannelHandlerContext) {
            reads += 1
            context.read()
        }
    }

    /// The steady-state pump: each yield the consumer has room for pulls the next read,
    /// so a body larger than the watermark keeps moving without anything else nudging it.
    @Test func eachAcceptedChunkPullsTheNextRead() async throws {
        let channel = EmbeddedChannel()
        let counter = ReadCounter()
        try channel.pipeline.addHandler(counter).wait()
        try channel.setOption(ChannelOptions.autoRead, value: false).wait()

        let bridge = RequestBodyBridge(capture: RequestBodyCapture())
        // The producer is built with `finishOnDeinit: false` (the engine finishes it
        // explicitly on `.end`), so a test that drops one un-finished traps in NIO.
        bridge.attach(channel: channel)
        bridge.yield(Data("one".utf8))
        bridge.yield(Data("two".utf8))
        #expect(counter.reads >= 2, "a yield the consumer has room for asks for more")

        // And the bytes are what the consumer sees, in order.
        bridge.finish()
        var collected = Data()
        for try await chunk in bridge.chunks { collected.append(chunk) }
        #expect(collected == Data("onetwo".utf8))

        _ = try channel.finish()
    }

    /// A terminated consumer must stop the pump: reads after teardown would keep
    /// pulling bytes nobody is waiting for.
    @Test func aTerminatedConsumerStopsTheReads() throws {
        let channel = EmbeddedChannel()
        let counter = ReadCounter()
        try channel.pipeline.addHandler(counter).wait()
        try channel.setOption(ChannelOptions.autoRead, value: false).wait()

        let bridge = RequestBodyBridge(capture: RequestBodyCapture())
        defer { bridge.finish() }
        bridge.attach(channel: channel)
        bridge.yield(Data("one".utf8))
        let before = counter.reads
        #expect(before > 0, "precondition: the pump was running")

        bridge.delegate.didTerminate()
        bridge.yield(Data("two".utf8))
        #expect(counter.reads == before, "no reads once the consumer is gone")

        _ = try channel.finish()
    }

    /// End to end through the real handler: a streamed upload whose body is larger than
    /// the watermark completes, with the whole body reaching upstream. This is the plain
    /// HTTP shape of what the h2 test exercises — same pump, no TLS or h2 in the way.
    @Test func aStreamedUploadLargerThanTheWatermarkCompletes() async throws {
        let upstream = PumpStubUpstream()
        let store = FlowStore(persistence: nil)
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { try? group.syncShutdownGracefully() }
        let channel = EmbeddedChannel()
        try channel.pipeline.addHandler(ProxyHandler(
            store: store, group: group, forwarder: upstream, ca: nil,
            config: InterceptionConfig(defaults: nil)
        )).wait()

        var head = HTTPRequestHead(version: .http1_1, method: .POST, uri: "http://api.example.test/upload")
        head.headers.add(name: "Host", value: "api.example.test")
        try channel.writeInbound(HTTPServerRequestPart.head(head))

        // Ten chunks — more than the bridge's high watermark, so the upload only
        // finishes if each consumed chunk pulls the next read.
        var expected = Data()
        for index in 0 ..< 10 {
            let chunk = Data(repeating: UInt8(index), count: 1_024)
            expected.append(chunk)
            var buffer = channel.allocator.buffer(capacity: chunk.count)
            buffer.writeBytes(chunk)
            try channel.writeInbound(HTTPServerRequestPart.body(buffer))
        }
        try channel.writeInbound(HTTPServerRequestPart.end(nil))

        // The forwarder runs on a Task; give it a bounded chance to drain rather than
        // hanging the suite if the pump stalls.
        for _ in 0 ..< 200 where await upstream.lastBody == nil {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(await upstream.lastBody == expected, "every chunk must reach upstream, in order")
        _ = try? channel.finish()
    }
}

private actor PumpStubUpstream: UpstreamForwarding {
    private(set) var lastBody: Data?

    func forward(method: String, url: URL, headers: [HeaderPair], body: Data?) async throws -> ForwardResult {
        lastBody = body
        return ForwardResult(statusCode: 200, headers: [], body: Data("ok".utf8))
    }
}
