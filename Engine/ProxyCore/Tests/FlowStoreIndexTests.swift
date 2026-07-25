import Testing
import Foundation
@testable import LoomProxyCore
import LoomSharedModels

/// `upsert` is the hottest thing on the capture path — an exchange upserts at
/// least twice (pending → completed), a streaming one more, a WebSocket once per
/// frame — and it used to locate the existing flow with a linear scan of the ring.
/// It's now an id→position map, with positions kept *absolute* so front eviction
/// doesn't invalidate them. These tests pin the invariants that indirection can
/// break: identity, ordering, eviction, and the byte accounting that rides along.
@Suite struct FlowStoreIndexTests {
    private func flow(_ n: Int, id: UUID = UUID(), status: Int? = nil, body: Data? = nil) -> Flow {
        Flow(
            id: id,
            request: CapturedRequest(method: "GET", url: "https://api.test/\(n)", headers: []),
            startedAt: Date(timeIntervalSince1970: TimeInterval(n)),
            outcome: status.map {
                .completed(CapturedResponse(statusCode: $0, headers: [], body: body), at: Date(timeIntervalSince1970: TimeInterval(n) + 1))
            } ?? .pending
        )
    }

    @Test func upsert_sameID_updatesInPlace() async {
        let store = FlowStore()
        let id = UUID()
        await store.upsert(flow(1, id: id))
        await store.upsert(flow(1, id: id, status: 200))
        #expect(await store.count == 1, "an update must not append a second row")
        #expect(await store.flow(id: id)?.statusCode == 200)
    }

    /// The case the absolute-position scheme exists for: after the front is evicted
    /// every surviving flow must still be addressable, and updates must land on the
    /// right one.
    @Test func upsert_afterEviction_stillUpdatesTheRightFlow() async {
        let store = FlowStore(capacity: 3)
        let ids = (0 ..< 5).map { _ in UUID() }
        for (offset, id) in ids.enumerated() { await store.upsert(flow(offset, id: id)) }
        // Ring holds the last three (2, 3, 4); 0 and 1 were evicted.
        #expect(await store.count == 3)

        await store.upsert(flow(3, id: ids[3], status: 503))
        #expect(await store.count == 3, "updating a survivor must not grow the ring")
        #expect(await store.flow(id: ids[3])?.statusCode == 503)
        // Its neighbours are untouched.
        #expect(await store.flow(id: ids[2])?.statusCode == nil)
        #expect(await store.flow(id: ids[4])?.statusCode == nil)
        // And the evicted ones are gone (no persistence to read through to).
        #expect(await store.flow(id: ids[0]) == nil)
        #expect(await store.flow(id: ids[1]) == nil)
    }

    @Test func eviction_keepsOrderNewestLast() async {
        let store = FlowStore(capacity: 3)
        for index in 0 ..< 6 { await store.upsert(flow(index)) }
        let recent = await store.recent(limit: 10)
        #expect(recent.map(\.request.url) == [
            "https://api.test/5", "https://api.test/4", "https://api.test/3",
        ], "newest-first, oldest evicted")
    }

    /// A stale map entry must never resolve to a *different* flow's slot.
    @Test func evictedID_doesNotResolveToAnotherSlot() async {
        let store = FlowStore(capacity: 2)
        let evicted = UUID()
        await store.upsert(flow(0, id: evicted))
        await store.upsert(flow(1))
        await store.upsert(flow(2))
        #expect(await store.flow(id: evicted) == nil)
        // Re-upserting an evicted id is a fresh insert, not a phantom update.
        await store.upsert(flow(0, id: evicted, status: 404))
        #expect(await store.count == 2)
        #expect(await store.flow(id: evicted)?.statusCode == 404)
    }

    @Test func clear_thenUpsert_startsCleanlyIndexed() async {
        let store = FlowStore(capacity: 3)
        for index in 0 ..< 3 { await store.upsert(flow(index)) }
        await store.clear()
        #expect(await store.count == 0)

        let id = UUID()
        await store.upsert(flow(9, id: id))
        await store.upsert(flow(9, id: id, status: 201))
        #expect(await store.count == 1, "positions were reset with the ring")
        #expect(await store.flow(id: id)?.statusCode == 201)
    }

    /// Body accounting is updated relative to the flow being replaced, so it must
    /// see the *same* flow the index points at.
    @Test func upsert_replacingBody_keepsByteAccountingConsistent() async {
        // A tiny budget with no persistence: `enforceBodyBudget` can't slim anything
        // (nothing is on disk), so the ring must simply stay correct.
        let store = FlowStore(capacity: 4, bodyBudget: 100)
        let id = UUID()
        await store.upsert(flow(1, id: id, status: 200, body: Data(repeating: 0x41, count: 500)))
        await store.upsert(flow(1, id: id, status: 200, body: Data(repeating: 0x42, count: 10)))
        #expect(await store.count == 1)
        #expect(await store.flow(id: id)?.response?.body?.count == 10)
    }

    @Test func manyUpsertsAcrossAFullRing_stayConsistent() async {
        let store = FlowStore(capacity: 50)
        var ids: [UUID] = []
        for index in 0 ..< 500 {
            let id = UUID()
            ids.append(id)
            await store.upsert(flow(index, id: id))
            await store.upsert(flow(index, id: id, status: 200)) // the completion upsert
        }
        #expect(await store.count == 50, "capacity holds under churn")
        // Every survivor is the completed version, addressed by its own id.
        for id in ids.suffix(50) {
            #expect(await store.flow(id: id)?.statusCode == 200)
        }
        for id in ids.prefix(450) {
            #expect(await store.flow(id: id) == nil)
        }
    }
}
