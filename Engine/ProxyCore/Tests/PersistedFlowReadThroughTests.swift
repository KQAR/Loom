import Testing
import Foundation
@testable import LoomProxyCore
import LoomSharedModels

/// The durable store keeps an order of magnitude more flows (20k rows) than the
/// in-memory ring (2k), but reads only ever consulted the ring — so past the ring
/// the store was effectively write-only: `get_flow_detail` / `diff_flows` /
/// `replay` answered "no flow with id X" for a flow sitting on disk, and an agent
/// holding a legitimate id concluded the exchange never happened.
@Suite final class PersistedFlowReadThroughTests {
    private let fileURL: URL

    init() {
        fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("loom-readthrough-\(UUID())", isDirectory: true)
            .appendingPathComponent("flows.sqlite")
    }

    deinit {
        try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent())
    }

    private func flow(_ n: Int, body: Data? = nil) -> Flow {
        Flow(
            id: UUID(),
            request: CapturedRequest(method: "GET", url: "https://api.test/\(n)", headers: []),
            startedAt: Date(timeIntervalSince1970: TimeInterval(n)),
            outcome: .completed(
                CapturedResponse(statusCode: 200, headers: [], body: body ?? Data("body\(n)".utf8)),
                at: Date(timeIntervalSince1970: TimeInterval(n) + 0.1)
            )
        )
    }

    @Test func persistence_flowByID_returnsMetadataAndBodies() throws {
        let store = try #require(FlowPersistence(fileURL: fileURL))
        let saved = flow(1, body: Data("hello".utf8))
        store.save(saved)
        store.flush()

        let loaded = try #require(store.flow(id: saved.id))
        #expect(loaded.id == saved.id)
        #expect(loaded.request.url == "https://api.test/1")
        #expect(loaded.response?.body == Data("hello".utf8), "bodies come back from their column")
    }

    @Test func persistence_flowByID_unknownID_isNil() throws {
        let store = try #require(FlowPersistence(fileURL: fileURL))
        #expect(store.flow(id: UUID()) == nil)
    }

    /// A WebSocket flow loaded at boot carries frames without bytes; the detail read
    /// is what puts them back, the same way it does a slimmed body.
    @Test func store_bootLoadedWebSocketFlow_hydratesItsFrames() async throws {
        let messages = [
            WebSocketMessage(direction: .serverToClient, kind: .text, payload: Data("tick".utf8), timestamp: Date(timeIntervalSince1970: 1)),
        ]
        let saved = Flow(
            id: UUID(),
            request: CapturedRequest(method: "GET", url: "wss://ws.test/", headers: []),
            startedAt: Date(timeIntervalSince1970: 1),
            outcome: .completed(CapturedResponse(statusCode: 101, headers: []), at: Date(timeIntervalSince1970: 2)),
            webSocketMessages: messages
        )
        do {
            let persistence = try #require(FlowPersistence(fileURL: fileURL))
            persistence.save(saved)
            persistence.flush()
        }
        let persistence = try #require(FlowPersistence(fileURL: fileURL))
        let store = FlowStore(capacity: 10, persistence: persistence)
        await store.loadPersisted(limit: 10)

        #expect(await store.recent(limit: 1).first?.webSocketPayloadsStripped == true, "the list read stays byte-free")
        #expect(await store.flow(id: saved.id)?.webSocketMessages == messages)
    }

    /// The actual bug: evicted from a tiny ring, still on disk, still resolvable.
    @Test func store_flowAgedOutOfTheRing_stillResolves() async throws {
        let persistence = try #require(FlowPersistence(fileURL: fileURL))
        let store = FlowStore(capacity: 2, persistence: persistence)

        let first = flow(1, body: Data("first".utf8))
        await store.upsert(first)
        await store.upsert(flow(2))
        await store.upsert(flow(3)) // evicts `first` from the 2-slot ring
        await store.flush()

        #expect(await store.count == 2)
        let recovered = try #require(await store.flow(id: first.id))
        #expect(recovered.request.url == "https://api.test/1")
        #expect(recovered.response?.body == Data("first".utf8), "with its body")
    }

    @Test func store_unknownID_isStillNil() async throws {
        let persistence = try #require(FlowPersistence(fileURL: fileURL))
        let store = FlowStore(capacity: 2, persistence: persistence)
        await store.upsert(flow(1))
        await store.flush()
        #expect(await store.flow(id: UUID()) == nil)
    }

    /// Without a durable store there is nothing to read through to — the ring is
    /// the whole truth (the embeddable `persistFlows: false` shape).
    @Test func store_withoutPersistence_doesNotResurrect() async {
        let store = FlowStore(capacity: 1, persistence: nil)
        let first = flow(1)
        await store.upsert(first)
        await store.upsert(flow(2))
        #expect(await store.flow(id: first.id) == nil)
    }

    /// "Export the last N" must not quietly return only what's in memory.
    @Test func recentHydrated_topsUpFromDisk() async throws {
        let persistence = try #require(FlowPersistence(fileURL: fileURL))
        let store = FlowStore(capacity: 2, persistence: persistence)
        for index in 1 ... 6 { await store.upsert(flow(index)) }
        await store.flush()

        #expect(await store.count == 2, "the ring only holds two")
        let exported = await store.recentHydrated(limit: 6)
        #expect(exported.count == 6, "the export spans the durable store")
        #expect(exported.map(\.request.url) == (1 ... 6).reversed().map { "https://api.test/\($0)" },
                "newest-first, no duplicates between ring and disk")
        #expect(exported.allSatisfy { $0.response?.body != nil }, "bodies hydrated for every entry")
    }

    /// The `export_har(host:)` bug: the newest `limit` were taken first and filtered
    /// after, so a host whose traffic had aged out of the ring exported nothing.
    @Test func searchHydrated_filtersBeforeTheLimit_andReachesDisk() async throws {
        let persistence = try #require(FlowPersistence(fileURL: fileURL))
        let store = FlowStore(capacity: 2, persistence: persistence)
        func at(_ host: String, _ n: Int) -> Flow {
            var flow = flow(n, body: Data("b\(n)".utf8))
            flow.request.url = "https://\(host)/\(n)"
            return flow
        }
        for n in 1 ... 3 { await store.upsert(at("ep1.facebook.com", n)) }
        await store.upsert(at("cdn.facebook.com", 4))
        await store.upsert(at("notfacebook.com.evil", 5))
        for n in 6 ... 9 { await store.upsert(at("noise.test", n)) }
        await store.flush()

        var exact = FlowQuery()
        exact.host = "ep1.facebook.com"
        let exported = await store.searchHydrated(matching: exact, limit: 2)
        #expect(exported.flows.map(\.request.url) == ["https://ep1.facebook.com/3", "https://ep1.facebook.com/2"],
                "every match is on disk, out of the 2-slot ring; limit applies after the filter")
        #expect(exported.flows.map { $0.response?.body } == [Data("b3".utf8), Data("b2".utf8)], "bodies hydrated")
        #expect(exported.budgetExhausted == false)
        #expect(exported.storedFlowCount == 9)

        var glob = FlowQuery()
        glob.host = "*.facebook.com"
        let globbed = await store.searchHydrated(matching: glob, limit: 10)
        #expect(globbed.flows.map(\.request.url).sorted() == [
            "https://cdn.facebook.com/4", "https://ep1.facebook.com/1",
            "https://ep1.facebook.com/2", "https://ep1.facebook.com/3",
        ], "a glob, not a substring: `notfacebook.com.evil` stays out")

        var substring = FlowQuery()
        substring.host = "facebook"
        #expect(await store.searchHydrated(matching: substring, limit: 10).flows.isEmpty,
                "host is exact or glob, like every other filter")
    }

    @Test func recentHydrated_ringSatisfiesTheLimit_doesNotTouchDisk() async throws {
        let persistence = try #require(FlowPersistence(fileURL: fileURL))
        let store = FlowStore(capacity: 10, persistence: persistence)
        for index in 1 ... 5 { await store.upsert(flow(index)) }
        await store.flush()
        let exported = await store.recentHydrated(limit: 3)
        #expect(exported.count == 3)
        #expect(exported.first?.request.url == "https://api.test/5")
    }
}
