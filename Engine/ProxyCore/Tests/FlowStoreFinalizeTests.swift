import Testing
import Foundation
@testable import ProxyCore
import SharedModels

/// Quit-time finalize contract: in-flight flows (`.pending` / `.streaming`) live
/// only in the ring, so `finalizeInFlight` must terminal-state them as failed and
/// persist them before the process dies — while leaving already-terminal flows
/// untouched.
@Suite struct FlowStoreFinalizeTests {
    private let reason = "interrupted (app quit)"

    private func request(_ n: Int) -> CapturedRequest {
        CapturedRequest(method: "GET", url: "https://api.test/\(n)", headers: [])
    }

    private func pending(_ n: Int) -> Flow {
        Flow(id: UUID(), request: request(n), startedAt: Date(timeIntervalSince1970: TimeInterval(n)), outcome: .pending)
    }

    private func streaming(_ n: Int) -> Flow {
        Flow(
            id: UUID(), request: request(n), startedAt: Date(timeIntervalSince1970: TimeInterval(n)),
            outcome: .streaming(CapturedResponse(statusCode: 200, headers: [], body: Data("partial\(n)".utf8)))
        )
    }

    private func completed(_ n: Int) -> Flow {
        Flow(
            id: UUID(), request: request(n), startedAt: Date(timeIntervalSince1970: TimeInterval(n)),
            outcome: .completed(CapturedResponse(statusCode: 200, headers: []), at: Date(timeIntervalSince1970: TimeInterval(n) + 1))
        )
    }

    @Test func pending_becomesFailedInterrupted() async {
        let store = FlowStore()
        let id = UUID()
        await store.upsert(Flow(id: id, request: request(1), startedAt: Date(timeIntervalSince1970: 1), outcome: .pending))

        let n = await store.finalizeInFlight(reason: reason)
        #expect(n == 1)

        let flow = await store.flow(id: id)
        #expect(flow?.error == reason)
        #expect(flow?.response == nil, "a flow that never got a response head has no partial")
    }

    @Test func streaming_preservesPartialResponse() async {
        let store = FlowStore()
        let flow = streaming(2)
        await store.upsert(flow)

        await store.finalizeInFlight(reason: reason)

        let finalized = await store.flow(id: flow.id)
        #expect(finalized?.error == reason)
        #expect(finalized?.response?.body == Data("partial2".utf8), "mid-stream bytes survive as the partial response")
    }

    @Test func terminalFlowsUntouched() async {
        let store = FlowStore()
        let done = completed(3)
        await store.upsert(done)

        let n = await store.finalizeInFlight(reason: reason)
        #expect(n == 0, "already-completed flows are not re-finalized")

        let flow = await store.flow(id: done.id)
        #expect(flow?.error == nil)
        #expect(flow?.statusCode == 200)
    }

    @Test func returnsCountOfInFlightOnly() async {
        let store = FlowStore()
        await store.upsert(pending(1))
        await store.upsert(streaming(2))
        await store.upsert(completed(3))

        let n = await store.finalizeInFlight(reason: reason)
        #expect(n == 2, "two in-flight (pending + streaming), the completed one skipped")
    }

    @Test func persistsFinalizedInFlightFlow() async throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("loom-finalize-\(UUID())", isDirectory: true)
            .appendingPathComponent("flows.sqlite")
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }

        let persistence = try #require(FlowPersistence(fileURL: fileURL))
        let store = FlowStore(persistence: persistence)
        await store.upsert(pending(1)) // in-flight → normally never persisted

        await store.finalizeInFlight(reason: reason)
        await store.flush() // drain the async save

        let persisted = persistence.recent(limit: 10)
        #expect(persisted.count == 1, "the finalized in-flight flow reached disk")
        #expect(persisted.first?.error == reason)
    }
}
