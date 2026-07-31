import Testing
import Foundation
import NIOCore
import NIOEmbedded
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
/// Scope, learned the hard way from a TSan failure on main: an `EmbeddedChannel` may
/// only be touched by one thread, so these tests keep **every** channel interaction on
/// the test thread and detach the delegate before any async consumption. A first version
/// also drove `ProxyHandler` end-to-end on one, which raced immediately — the handler's
/// exchange runs on a `Task`, and `StreamRelay` then writes to the channel from that
/// thread. Anything covering the handler needs a real channel (see
/// `HTTPSInterceptionTests`) or `NIOAsyncTestingChannel`.
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

        // Detach before consuming: `produceMore` can fire from whichever thread the
        // consumer resumes on, and an `EmbeddedChannel` may only be touched by one.
        // (The three assertions above already covered the reads.)
        bridge.delegate.didTerminate()
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

    /// `RequestBodyBridge.readsIssued` is the diagnostic that tells the h2 upload
    /// stall (issue #99, upstream's missing WINDOW_UPDATE) apart from a Loom-side
    /// read-pump regression: both park with exactly one 65535-byte window consumed,
    /// so the byte counters alone can't distinguish them, and the documented
    /// discriminator would wave a real regression through as the known flake.
    ///
    /// Pinned here because a counter that silently stops counting is worse than no
    /// counter — it reads as "we never asked", i.e. it would accuse Loom.
    @Test func readsIssuedTracksTheActualReads() throws {
        let channel = EmbeddedChannel()
        let counter = ReadCounter()
        try channel.pipeline.addHandler(counter).wait()
        try channel.setOption(ChannelOptions.autoRead, value: false).wait()

        let bridge = RequestBodyBridge(capture: RequestBodyCapture())
        defer { bridge.finish() }
        // Process-wide and cumulative (other tests in this bundle stream bodies too),
        // so compare deltas, never absolutes.
        let before = RequestBodyBridge.readsIssued
        let pipelineBefore = counter.reads

        bridge.attach(channel: channel)
        bridge.yield(Data("one".utf8))
        bridge.yield(Data("two".utf8))

        let issued = RequestBodyBridge.readsIssued - before
        #expect(issued == counter.reads - pipelineBefore,
                "every counted read must be one that actually reached the pipeline")
        #expect(issued > 0, "a running pump must register reads, or the report accuses Loom of never asking")

        // A stopped pump must stop the counter too — otherwise a frozen pump would
        // still look like it was asking for more, which is the opposite mistake.
        bridge.delegate.didTerminate()
        let afterTeardown = RequestBodyBridge.readsIssued
        bridge.yield(Data("three".utf8))
        #expect(RequestBodyBridge.readsIssued == afterTeardown)

        _ = try channel.finish()
    }
}
