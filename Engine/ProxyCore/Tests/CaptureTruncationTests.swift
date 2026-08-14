import Testing
import Foundation
import NIOCore
import NIOEmbedded
@testable import LoomProxyCore
import LoomSharedModels

/// The capture caps exist so an endless stream / huge upload can't grow the store
/// without bound — but a capped capture must never *look* like a complete one. A
/// truncated body records the real wire size; a complete one records nothing.
/// Without this, an agent diffing or parsing a body silently reasons about a
/// prefix (a half-JSON document reads as "the server returned malformed JSON").
@Suite struct CaptureTruncationTests {
    private let url = URL(string: "https://api.example.test/v1/stream")!

    /// Relay a response of `chunks` through `StreamRelay` with the given cap and
    /// return the recorded flow.
    private func relay(chunks: [Data], cap: Int) async throws -> Flow? {
        let store = FlowStore()
        let flowID = UUID()
        let (stream, continuation) = AsyncThrowingStream<UpstreamResponseEvent, Error>.makeStream()
        continuation.yield(.head(statusCode: 200, httpVersion: "HTTP/1.1", headers: []))
        for chunk in chunks { continuation.yield(.body(chunk)) }
        continuation.yield(.end(trailers: nil))
        continuation.finish()

        let channel = EmbeddedChannel()
        try await channel.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 1)).get()
        await StreamRelay.relay(
            stream: stream, channel: channel, keepAlive: false, flowID: flowID,
            request: CapturedRequest(method: "GET", url: url.absoluteString, headers: [], body: nil),
            startedAt: Date(), sourceApp: nil, sourceDevice: nil, store: store, captureCap: cap
        )
        _ = try? channel.finish()
        return await store.flow(id: flowID)
    }

    @Test func responseUnderCap_recordsNoTruncation() async throws {
        let flow = try await relay(chunks: [Data(repeating: 0x41, count: 30)], cap: 100)
        let response = try #require(flow?.response)
        #expect(response.body?.count == 30)
        #expect(response.fullBodyBytes == nil)
        #expect(response.isBodyTruncated == false)
    }

    @Test func responseOverCap_isFlaggedWithTheWireSize() async throws {
        // 4 × 40 bytes = 160 on the wire; only 100 are kept.
        let flow = try await relay(chunks: Array(repeating: Data(repeating: 0x42, count: 40), count: 4), cap: 100)
        let response = try #require(flow?.response)
        #expect(response.body?.count == 100, "the stored copy stops at the cap")
        #expect(response.fullBodyBytes == 160, "…but the flow reports what actually flowed")
        #expect(response.isBodyTruncated)
    }

    @Test func requestBodyOverCap_isFlaggedOnTheCapturedRequest() async throws {
        let store = FlowStore()
        let flowID = UUID()
        let capture = RequestBodyCapture(cap: 50)
        capture.append(Data(repeating: 0x43, count: 200)) // a 200-byte upload, 50 kept

        let (stream, continuation) = AsyncThrowingStream<UpstreamResponseEvent, Error>.makeStream()
        continuation.yield(.head(statusCode: 200, httpVersion: "HTTP/1.1", headers: []))
        continuation.yield(.end(trailers: nil))
        continuation.finish()

        let channel = EmbeddedChannel()
        try await channel.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 1)).get()
        await StreamRelay.relay(
            stream: stream, channel: channel, keepAlive: false, flowID: flowID,
            request: CapturedRequest(method: "POST", url: url.absoluteString, headers: [], body: nil),
            startedAt: Date(), sourceApp: nil, sourceDevice: nil, store: store, bodyCapture: capture
        )
        _ = try? channel.finish()

        let flow = await store.flow(id: flowID)
        #expect(flow?.request.body?.count == 50)
        #expect(flow?.request.fullBodyBytes == 200)
    }

    /// The flag must survive the strip/hydrate round trip the store and SQLite use —
    /// otherwise a flow reloaded from disk claims to be complete.
    @Test func truncationFlag_survivesStripAndHydrate() {
        let flow = Flow(
            id: UUID(),
            request: CapturedRequest(
                method: "POST", url: url.absoluteString, headers: [],
                body: Data(repeating: 0x41, count: 10), fullBodyBytes: 999
            ),
            startedAt: Date(),
            outcome: .completed(
                CapturedResponse(
                    statusCode: 200, headers: [],
                    body: Data(repeating: 0x42, count: 10), fullBodyBytes: 777
                ),
                at: Date()
            )
        )
        let stripped = flow.strippingBodies()
        #expect(stripped.request.fullBodyBytes == 999)
        #expect(stripped.response?.fullBodyBytes == 777)

        let hydrated = stripped.attachingBodies(request: Data(count: 10), response: Data(count: 10))
        #expect(hydrated.request.isBodyTruncated)
        #expect(hydrated.response?.isBodyTruncated == true)
    }

    /// A flow persisted before the field existed must still decode (the key is
    /// simply absent) and read as un-truncated.
    @Test func legacyEncodedFlow_decodesAsUntruncated() throws {
        let json = """
        {"id":"\(UUID().uuidString)",
         "request":{"method":"GET","url":"https://a/","headers":[]},
         "startedAt":0,
         "outcome":{"pending":{}}}
        """
        let flow = try JSONDecoder().decode(Flow.self, from: Data(json.utf8))
        #expect(flow.request.fullBodyBytes == nil)
        #expect(flow.request.isBodyTruncated == false)
        #expect(flow.webSocketDroppedMessages == nil)
    }
}
