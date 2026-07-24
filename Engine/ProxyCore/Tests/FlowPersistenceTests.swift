import Testing
import Foundation
@testable import LoomProxyCore
import LoomSharedModels

@Suite final class FlowPersistenceTests {
    private let fileURL: URL

    init() {
        fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("loom-flows-\(UUID())", isDirectory: true)
            .appendingPathComponent("flows.sqlite")
    }

    deinit {
        try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent())
    }

    private func flow(_ n: Int, method: String = "GET") -> Flow {
        Flow(
            id: UUID(),
            request: CapturedRequest(method: method, url: "https://api.test/\(n)", headers: []),
            startedAt: Date(timeIntervalSince1970: TimeInterval(n)),
            outcome: .completed(
                CapturedResponse(statusCode: 200, headers: [], body: Data("body\(n)".utf8)),
                at: Date(timeIntervalSince1970: TimeInterval(n) + 0.1)
            )
        )
    }

    @Test func saveAndRecent_roundTrips_bodyFree() throws {
        let store = try #require(FlowPersistence(fileURL: fileURL))
        store.save(flow(1))
        store.save(flow(2))
        let recent = store.recent(limit: 10) // sync — save's async writes drain on the same serial queue
        #expect(recent.count == 2)
        #expect(recent.first?.request.url == "https://api.test/2", "newest first")
        // Layer 1: the metadata read is body-free; bodies live in their own columns.
        #expect(recent.first?.response?.body == nil, "recent() no longer carries bodies")
    }

    @Test func bodies_roundTrip() throws {
        let store = try #require(FlowPersistence(fileURL: fileURL))
        store.save(flow(2))
        _ = store.recent(limit: 1) // drain the async write
        let firstFlow = try #require(store.recent(limit: 1).first)
        let bodies = try #require(store.bodies(id: firstFlow.id))
        #expect(bodies.response == Data("body2".utf8))
        #expect(bodies.request == nil, "this fixture has no request body")
    }

    @Test func bodies_missingRow_isNil() throws {
        let store = try #require(FlowPersistence(fileURL: fileURL))
        #expect(store.bodies(id: UUID()) == nil)
    }

    @Test func survivesReopen() throws {
        do {
            let store = try #require(FlowPersistence(fileURL: fileURL))
            store.save(flow(1))
            _ = store.recent(limit: 1) // drain the write
        }
        let reopened = try #require(FlowPersistence(fileURL: fileURL))
        #expect(reopened.recent(limit: 10).count == 1, "rows persist across instances")
    }

    @Test func deleteAll() throws {
        let store = try #require(FlowPersistence(fileURL: fileURL))
        store.save(flow(1))
        store.deleteAll()
        #expect(store.recent(limit: 10).isEmpty)
    }

    @Test func flowStore_reloadedFlowIsBodyFree_butHydratesOnDetail() async throws {
        let persistence = try #require(FlowPersistence(fileURL: fileURL))
        let saved = flow(2)
        persistence.save(saved)
        _ = persistence.recent(limit: 1) // drain

        let store = FlowStore(persistence: persistence)
        await store.loadPersisted(limit: 10)

        // The ring holds the reloaded flow body-free (Layer 1 RAM win)…
        let listed = await store.recent(limit: 10).first
        #expect(listed?.response?.body == nil)
        // …but a detail read hydrates the body back from disk.
        let detailed = await store.flow(id: saved.id)
        #expect(detailed?.response?.body == Data("body2".utf8))
    }

    @Test func flowStore_loadsPersistedOnce() async throws {
        let persistence = try #require(FlowPersistence(fileURL: fileURL))
        persistence.save(flow(1))
        persistence.save(flow(2))
        _ = persistence.recent(limit: 1) // drain

        let store = FlowStore(persistence: persistence)
        await store.loadPersisted(limit: 10)
        let count = await store.count
        #expect(count == 2)
        let recent = await store.recent(limit: 10)
        #expect(recent.first?.request.url == "https://api.test/2")
    }
}
