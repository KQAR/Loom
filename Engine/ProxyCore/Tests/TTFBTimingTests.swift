import Testing
import Foundation
import NIOCore
import NIOEmbedded
@testable import LoomProxyCore
import LoomSharedModels

/// A single `durationMS` can't answer the question people actually ask a debugging
/// proxy — *why* is this slow. Waiting 2s for a response head (server) and
/// streaming a 20 MB body in 2s (payload/link) are the same duration and different
/// bugs. `firstByteAt` splits them.
@Suite struct TTFBTimingTests {
    private let url = URL(string: "https://api.example.test/v1/slow")!

    @Test func ttfbAndReceive_derivedFromFirstByte() {
        let start = Date(timeIntervalSince1970: 1_000)
        let flow = Flow(
            id: UUID(),
            request: CapturedRequest(method: "GET", url: url.absoluteString, headers: []),
            startedAt: start,
            outcome: .completed(CapturedResponse(statusCode: 200, headers: []), at: start.addingTimeInterval(2.5)),
            firstByteAt: start.addingTimeInterval(2.0)
        )
        #expect(flow.ttfbMS == 2_000)
        #expect(flow.receiveMS == 500)
        #expect(flow.durationMS == 2_500)
        #expect(flow.ttfbMS! + flow.receiveMS! == flow.durationMS!, "the split must add up")
    }

    @Test func noFirstByte_meansNoTTFB_ratherThanZero() {
        let start = Date(timeIntervalSince1970: 1_000)
        let failed = Flow(
            id: UUID(),
            request: CapturedRequest(method: "GET", url: url.absoluteString, headers: []),
            startedAt: start,
            outcome: .failed(FlowError("connection refused"), at: start.addingTimeInterval(1), partialResponse: nil)
        )
        #expect(failed.ttfbMS == nil, "a flow that never got a head has no TTFB")
        #expect(failed.receiveMS == nil)
        #expect(failed.durationMS == 1_000)
    }

    /// The relay records the head arrival, so a slow-head / fast-body exchange is
    /// distinguishable from the reverse.
    @Test func streamRelay_recordsFirstByteOnTheHead() async throws {
        let store = FlowStore()
        let flowID = UUID()
        let (stream, continuation) = AsyncThrowingStream<UpstreamResponseEvent, Error>.makeStream()

        let channel = EmbeddedChannel()
        try await channel.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 1)).get()

        let relay = Task {
            await StreamRelay.relay(
                stream: stream, channel: channel, keepAlive: false, flowID: flowID,
                request: CapturedRequest(method: "GET", url: url.absoluteString, headers: [], body: nil),
                startedAt: Date(), sourceApp: nil, sourceDevice: nil, store: store
            )
        }
        // Delay the head, so TTFB is measurably non-zero and clearly separate from
        // the body that follows immediately after.
        try await Task.sleep(nanoseconds: 60_000_000)
        continuation.yield(.head(statusCode: 200, httpVersion: "HTTP/1.1", headers: []))
        continuation.yield(.body(Data("done".utf8)))
        continuation.yield(.end(trailers: nil))
        continuation.finish()
        await relay.value
        _ = try? channel.finish()

        let flow = try #require(await store.flow(id: flowID))
        let ttfb = try #require(flow.ttfbMS)
        #expect(ttfb >= 50, "the head took ~60ms; TTFB must reflect it (got \(ttfb)ms)")
        let receive = try #require(flow.receiveMS)
        #expect(receive < ttfb, "the body arrived immediately after the head")
    }

    @Test func streamRelay_failureBeforeHead_leavesTTFBUnset() async throws {
        struct Boom: Error {}
        let store = FlowStore()
        let flowID = UUID()
        let (stream, continuation) = AsyncThrowingStream<UpstreamResponseEvent, Error>.makeStream()
        continuation.finish(throwing: Boom())

        let channel = EmbeddedChannel()
        try await channel.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 1)).get()
        await StreamRelay.relay(
            stream: stream, channel: channel, keepAlive: false, flowID: flowID,
            request: CapturedRequest(method: "GET", url: url.absoluteString, headers: [], body: nil),
            startedAt: Date(), sourceApp: nil, sourceDevice: nil, store: store
        )
        _ = try? channel.finish()

        let flow = try #require(await store.flow(id: flowID))
        #expect(flow.firstByteAt == nil)
        #expect(flow.ttfbMS == nil)
    }

    /// Replay shares the capture path, so a replayed flow is comparable to the
    /// original it was replayed from — including on timing.
    @Test func replay_recordsFirstByte() async throws {
        let engine = ProxyEngine(forwarder: TimingStubUpstream(), caStore: InMemoryCAStore())
        let source = Flow(
            id: UUID(),
            request: CapturedRequest(method: "GET", url: url.absoluteString, headers: []),
            startedAt: Date(),
            outcome: .completed(CapturedResponse(statusCode: 200, headers: []), at: Date())
        )
        let replayed = try await engine.replay(flow: source, overrides: .none)
        #expect(replayed.firstByteAt != nil)
        #expect(replayed.ttfbMS != nil)

        await engine.stopForTest()
    }

    /// A flow persisted before TTFB existed decodes with it absent, not zero.
    @Test func legacyEncodedFlow_hasNoTTFB() throws {
        let json = """
        {"id":"\(UUID().uuidString)",
         "request":{"method":"GET","url":"https://a/","headers":[]},
         "startedAt":0,
         "outcome":{"completed":{"_0":{"statusCode":200,"headers":[]},"at":1}}}
        """
        let flow = try JSONDecoder().decode(Flow.self, from: Data(json.utf8))
        #expect(flow.firstByteAt == nil)
        #expect(flow.ttfbMS == nil)
        #expect(flow.durationMS == 1_000)
    }
}

private struct TimingStubUpstream: UpstreamForwarding {
    func forward(method: String, url: URL, headers: [HeaderPair], body: Data?) async throws -> ForwardResult {
        ForwardResult(statusCode: 200, headers: [], body: Data("ok".utf8))
    }
}
