import Testing
import Foundation
@testable import ProxyCore
import SharedModels

/// The Record toggle's engine contract: paused capture drops new flows but
/// still lets in-flight completions and explicit (forced) writes land.
@Suite struct FlowStoreRecordingTests {
    private func makeFlow(id: UUID = UUID(), completed: Bool = false) -> Flow {
        Flow(
            id: id,
            request: CapturedRequest(method: "GET", url: "http://example.test/", headers: []),
            startedAt: Date(timeIntervalSince1970: 0),
            outcome: completed
                ? .completed(CapturedResponse(statusCode: 200, headers: []), at: Date(timeIntervalSince1970: 1))
                : .pending
        )
    }

    @Test func recordsByDefault() async {
        let store = FlowStore()
        await store.upsert(makeFlow())
        let count = await store.count
        #expect(count == 1)
    }

    @Test func paused_dropsNewFlows() async {
        let store = FlowStore()
        await store.setRecording(false)
        await store.upsert(makeFlow())
        let count = await store.count
        #expect(count == 0, "paused capture must not record new flows")
    }

    @Test func paused_stillCompletesInFlightFlows() async {
        let store = FlowStore()
        let id = UUID()
        await store.upsert(makeFlow(id: id))          // captured while recording
        await store.setRecording(false)
        await store.upsert(makeFlow(id: id, completed: true)) // completion arrives after pause

        let flow = await store.flow(id: id)
        #expect(flow?.response?.statusCode == 200, "in-flight flows must not get stuck open")
        let count = await store.count
        #expect(count == 1)
    }

    @Test func paused_forcedUpsertStillRecords() async {
        let store = FlowStore()
        await store.setRecording(false)
        await store.upsert(makeFlow(), force: true)   // replay path
        let count = await store.count
        #expect(count == 1, "explicit actions (replay) record even while paused")
    }

    @Test func resume_recordsAgain() async {
        let store = FlowStore()
        await store.setRecording(false)
        await store.upsert(makeFlow())
        await store.setRecording(true)
        await store.upsert(makeFlow())
        let count = await store.count
        #expect(count == 1)
    }
}
