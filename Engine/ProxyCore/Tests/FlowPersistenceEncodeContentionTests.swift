import Foundation
import Testing
import LoomSharedModels
@testable import LoomProxyCore

/// Persisting a flow must not hold the `FlowStore` actor.
///
/// `FlowStore.upsert` hands every completed flow to `FlowPersistence.save`, and
/// `save` used to JSON-encode it right there, on the actor. For most flows that is
/// tens of microseconds; for a WebSocket flow it is the whole frame log — up to
/// 10 000 frames / 5 MB, base64-inflated into the `json` column — and every capture
/// write queued behind it. The encode now runs on the persistence queue (and the
/// frame bytes go to their own column), so the completing upsert costs what any
/// other upsert costs.
///
/// Measured (Debug, M-series, median of 7): the completing upsert took **37 ms** with
/// the encode on the caller and **0.008 ms** with it on the queue.
///
/// A timing assertion, for the reason `FlowStoreScanContentionTests` gives: the
/// property is "how long does a write wait". 5 ms is ~600× the real cost and ~7×
/// under the broken one, so a busy CI runner has room and a regression does not.
@Suite final class FlowPersistenceEncodeContentionTests {
    private let fileURL: URL

    init() {
        fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("loom-encode-\(UUID())", isDirectory: true)
            .appendingPathComponent("flows.sqlite")
    }

    deinit {
        try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent())
    }

    /// The capture cap's worth of frames: 10 000 × 500 B = 5 MB.
    private func closedWebSocketFlow() -> Flow {
        let payload = Data((0 ..< 500).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        let start = Date()
        let frames = (0 ..< 10_000).map { i in
            WebSocketMessage(
                direction: i.isMultiple(of: 2) ? .clientToServer : .serverToClient,
                kind: .binary, payload: payload, timestamp: start
            )
        }
        return Flow(
            request: CapturedRequest(method: "GET", url: "wss://feed.example.test/", headers: []),
            startedAt: start,
            outcome: .completed(CapturedResponse(statusCode: 101, headers: []), at: start),
            webSocketMessages: frames
        )
    }

    @Test func persistingALargeWebSocketFlowDoesNotHoldTheActor() async throws {
        let persistence = try #require(FlowPersistence(fileURL: fileURL))
        let store = FlowStore(capacity: 100, persistence: persistence)

        var samples: [Double] = []
        for _ in 0 ..< 7 {
            let flow = closedWebSocketFlow()
            let started = DispatchTime.now().uptimeNanoseconds
            await store.upsert(flow)
            samples.append(Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000)
        }
        persistence.flush()
        let median = samples.sorted()[samples.count / 2]
        #expect(
            median < 5,
            """
            Completing a 5 MB WebSocket flow held the store for \(median) ms. That is the \
            shape of `FlowPersistence.save` encoding on the caller — i.e. on the `FlowStore` \
            actor — again; the encode belongs on the persistence queue.
            """
        )
    }
}
