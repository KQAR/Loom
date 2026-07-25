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
