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

    private func webSocketFlow() -> Flow {
        Flow(
            id: UUID(),
            request: CapturedRequest(method: "GET", url: "wss://ws.test/feed", headers: []),
            startedAt: Date(timeIntervalSince1970: 50),
            outcome: .completed(CapturedResponse(statusCode: 101, headers: []), at: Date(timeIntervalSince1970: 51)),
            webSocketMessages: [
                WebSocketMessage(direction: .clientToServer, kind: .text, payload: Data("hello".utf8), timestamp: Date(timeIntervalSince1970: 50)),
                WebSocketMessage(direction: .serverToClient, kind: .ping, payload: Data(), timestamp: Date(timeIntervalSince1970: 50.5)),
                WebSocketMessage(direction: .serverToClient, kind: .binary, payload: Data([0, 1, 2]), timestamp: Date(timeIntervalSince1970: 51)),
            ]
        )
    }

    /// Frame payloads live in their own column: the list read keeps every frame's
    /// metadata and none of its bytes, and every hydrating read puts them back.
    @Test func webSocketPayloads_leaveTheJSONColumn_andHydrateBack() throws {
        let store = try #require(FlowPersistence(fileURL: fileURL))
        let saved = webSocketFlow()
        store.save(saved)

        let listed = try #require(store.recent(limit: 1).first)
        #expect(listed.webSocketMessages?.count == 3)
        #expect(listed.webSocketPayloadsStripped)

        #expect(store.flow(id: saved.id)?.webSocketMessages == saved.webSocketMessages)
        let frames = try #require(store.bodies(id: saved.id, includingWebSocket: true)?.webSocket)
        #expect(listed.attachingWebSocketPayloads(frames).webSocketMessages == saved.webSocketMessages)
        #expect(store.bodies(id: saved.id)?.webSocket == nil, "not read unless asked for")
    }

    @Test func webSocketPayloads_rejectAnythingButWholeFrames() throws {
        let messages = webSocketFlow().webSocketMessages
        let column = try #require(WebSocketPayloads.encode(messages))
        #expect(WebSocketPayloads.decode(column)?.count == 3)
        #expect(WebSocketPayloads.decode(column.dropLast()) == nil, "truncated payload")
        #expect(WebSocketPayloads.decode(Data([0, 0, 0])) == nil, "truncated length")
        #expect(WebSocketPayloads.decode(Data([0xFF, 0xFF, 0xFF, 0xFF])) == nil, "length past the end")
        #expect(WebSocketPayloads.encode([]) == nil)
        // A count mismatch attaches nothing rather than pairing bytes with the wrong frames.
        let stripped = webSocketFlow().strippingWebSocketPayloads()
        #expect(stripped.attachingWebSocketPayloads([Data("x".utf8)]) == stripped)
    }

    /// The row count bounded the store and nothing bounded its bytes. Past the body
    /// budget the oldest rows lose their bodies and keep everything else — and say so,
    /// so a later read reports "evicted, it was 1024 bytes", never "no body".
    @Test func overTheBodyBudget_theOldestRowsLoseTheirBodiesNotTheirRows() throws {
        let store = try #require(FlowPersistence(fileURL: fileURL, maxBodyBytes: 4096, protectedNewest: 1))
        let flows = (1 ... 10).map { n in
            Flow(
                id: UUID(),
                request: CapturedRequest(method: "GET", url: "https://api.test/\(n)", headers: []),
                startedAt: Date(timeIntervalSince1970: TimeInterval(n)),
                outcome: .completed(
                    CapturedResponse(statusCode: 200, headers: [], body: Data(repeating: 0x61, count: 1024)),
                    at: Date(timeIntervalSince1970: TimeInterval(n) + 0.1)
                )
            )
        }
        for flow in flows { store.save(flow) }
        store.flush()

        #expect(store.recent(limit: 100).count == 10, "eviction must never delete a row")
        let oldest = try #require(store.flow(id: flows[0].id))
        #expect(oldest.bodiesEvicted == true)
        #expect(oldest.response?.body == nil)
        #expect(oldest.response?.fullBodyBytes == 1024, "the size it had must survive the eviction")
        let newest = try #require(store.flow(id: flows[9].id))
        #expect(newest.response?.body?.count == 1024, "the protected newest rows keep their bodies")
        #expect(newest.bodiesEvicted == nil)

        let kept = flows.filter { store.flow(id: $0.id)?.response?.body != nil }.count
        #expect(kept * 1024 <= 4096, "the store is back under its budget")
    }

    /// A store already over its budget — written before the budget existed, or under a
    /// larger one — is brought under it on open, not at the next write.
    @Test func aStoreOverItsBudgetIsTrimmedOnOpen() throws {
        do {
            let store = try #require(FlowPersistence(fileURL: fileURL))
            for n in 1 ... 6 { store.save(flow(n)) }
            store.flush()
        }
        let reopened = try #require(FlowPersistence(fileURL: fileURL, maxBodyBytes: 0, protectedNewest: 0))
        #expect(reopened.recent(limit: 10).count == 6)
        #expect(reopened.recent(limit: 10).allSatisfy { reopened.flow(id: $0.id)?.bodiesEvicted == true })
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
