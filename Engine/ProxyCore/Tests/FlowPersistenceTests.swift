import XCTest
@testable import ProxyCore
import SharedModels

final class FlowPersistenceTests: XCTestCase {
    private var fileURL: URL!

    override func setUp() {
        super.setUp()
        fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("loom-flows-\(UUID())", isDirectory: true)
            .appendingPathComponent("flows.sqlite")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent())
        super.tearDown()
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

    func test_saveAndRecent_roundTrips_bodyFree() throws {
        let store = try XCTUnwrap(FlowPersistence(fileURL: fileURL))
        store.save(flow(1))
        store.save(flow(2))
        let recent = store.recent(limit: 10) // sync — save's async writes drain on the same serial queue
        XCTAssertEqual(recent.count, 2)
        XCTAssertEqual(recent.first?.request.url, "https://api.test/2", "newest first")
        // Layer 1: the metadata read is body-free; bodies live in their own columns.
        XCTAssertNil(recent.first?.response?.body, "recent() no longer carries bodies")
    }

    func test_bodies_roundTrip() throws {
        let store = try XCTUnwrap(FlowPersistence(fileURL: fileURL))
        store.save(flow(2))
        _ = store.recent(limit: 1) // drain the async write
        let bodies = try XCTUnwrap(store.bodies(id: try XCTUnwrap(store.recent(limit: 1).first).id))
        XCTAssertEqual(bodies.response, Data("body2".utf8))
        XCTAssertNil(bodies.request, "this fixture has no request body")
    }

    func test_bodies_missingRow_isNil() throws {
        let store = try XCTUnwrap(FlowPersistence(fileURL: fileURL))
        XCTAssertNil(store.bodies(id: UUID()))
    }

    func test_survivesReopen() throws {
        do {
            let store = try XCTUnwrap(FlowPersistence(fileURL: fileURL))
            store.save(flow(1))
            _ = store.recent(limit: 1) // drain the write
        }
        let reopened = try XCTUnwrap(FlowPersistence(fileURL: fileURL))
        XCTAssertEqual(reopened.recent(limit: 10).count, 1, "rows persist across instances")
    }

    func test_deleteAll() throws {
        let store = try XCTUnwrap(FlowPersistence(fileURL: fileURL))
        store.save(flow(1))
        store.deleteAll()
        XCTAssertTrue(store.recent(limit: 10).isEmpty)
    }

    func test_flowStore_reloadedFlowIsBodyFree_butHydratesOnDetail() async throws {
        let persistence = try XCTUnwrap(FlowPersistence(fileURL: fileURL))
        let saved = flow(2)
        persistence.save(saved)
        _ = persistence.recent(limit: 1) // drain

        let store = FlowStore(persistence: persistence)
        await store.loadPersisted(limit: 10)

        // The ring holds the reloaded flow body-free (Layer 1 RAM win)…
        let listed = await store.recent(limit: 10).first
        XCTAssertNil(listed?.response?.body)
        // …but a detail read hydrates the body back from disk.
        let detailed = await store.flow(id: saved.id)
        XCTAssertEqual(detailed?.response?.body, Data("body2".utf8))
    }

    func test_flowStore_loadsPersistedOnce() async throws {
        let persistence = try XCTUnwrap(FlowPersistence(fileURL: fileURL))
        persistence.save(flow(1))
        persistence.save(flow(2))
        _ = persistence.recent(limit: 1) // drain

        let store = FlowStore(persistence: persistence)
        await store.loadPersisted(limit: 10)
        let count = await store.count
        XCTAssertEqual(count, 2)
        let recent = await store.recent(limit: 10)
        XCTAssertEqual(recent.first?.request.url, "https://api.test/2")
    }
}
