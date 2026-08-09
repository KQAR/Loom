import Testing
import Foundation
@testable import LoomProxyCore
import LoomSharedModels

/// The ring's byte budget applies **without** a durable store too.
///
/// `enforceBodyBudget` used to open with `guard persistence != nil`, on reasoning that
/// was sound as far as it went — with nothing to hydrate from, dropping a body loses
/// it. The consequence was that an embedder running `ProxyEngine(persistFlows: false)`
/// had no body bound at all: the budget was a no-op and the ring held every byte it
/// was handed. Measured at a 20 000-flow ring with 32 KB bodies, **625 MB live**
/// against 61 MB for the same traffic with a store.
///
/// So the drop happens either way, and what the missing store changes is that it is a
/// loss — recorded as one, rather than leaving a flow that claims it had no body.
@Suite final class RingBodyBudgetWithoutStoreTests {
    private func flow(_ n: Int, bodyBytes: Int, requestBody: Int = 0) -> Flow {
        Flow(
            id: UUID(),
            request: CapturedRequest(
                method: "POST",
                url: "https://api.test/\(n)",
                headers: [],
                body: requestBody > 0 ? Data(repeating: 0x41, count: requestBody) : nil
            ),
            startedAt: Date(timeIntervalSince1970: TimeInterval(n)),
            outcome: .completed(
                CapturedResponse(
                    statusCode: 200, headers: [], body: Data(repeating: 0x42, count: bodyBytes)
                ),
                at: Date(timeIntervalSince1970: TimeInterval(n) + 0.1)
            )
        )
    }

    private func heldBodyBytes(_ store: FlowStore, limit: Int) async -> Int {
        await store.recent(limit: limit).reduce(0) {
            $0 + ($1.request.body?.count ?? 0) + ($1.response?.body?.count ?? 0)
        }
    }

    /// The bound itself: without this, the ring grew to whatever traffic it was given.
    @Test func theBudgetHoldsWithNoStore() async {
        let budget = 200_000
        let store = FlowStore(capacity: 100, bodyBudget: budget, persistence: nil)
        for n in 0..<50 { await store.upsert(flow(n, bodyBytes: 20_000)) }   // 1 MB offered

        let held = await heldBodyBytes(store, limit: 100)
        #expect(held <= budget, "in-memory bodies stay inside the budget: \(held) > \(budget)")
        #expect(await store.recent(limit: 100).count == 50, "only bodies go; metadata stays")
    }

    /// The load-bearing half: a dropped body must not read as an absent one.
    @Test func anEvictedBodyRecordsWhatFlowed() async {
        let store = FlowStore(capacity: 100, bodyBudget: 50_000, persistence: nil)
        for n in 0..<20 { await store.upsert(flow(n, bodyBytes: 20_000, requestBody: 4_000)) }

        let flows = await store.recent(limit: 100)
        let evicted = flows.filter { $0.bodiesEvicted == true }
        #expect(!evicted.isEmpty, "the budget had to drop something")
        for flow in evicted {
            #expect(flow.response?.body == nil)
            #expect(flow.response?.fullBodyBytes == 20_000, "the wire size survives the drop")
            #expect(flow.response?.isBodyTruncated == true, "so every reader of truncation sees it")
            #expect(flow.request.fullBodyBytes == 4_000, "both sides, not just the response")
        }
    }

    /// A body already capped at capture keeps the size it actually had on the wire —
    /// the recorded prefix simply becomes empty. Overwriting it with the prefix length
    /// would turn a 5 MB download into a 64 KB one.
    @Test func anAlreadyCappedBodyKeepsItsWireSize() {
        let capped = CapturedResponse(
            statusCode: 200, headers: [], body: Data(repeating: 0x42, count: 64_000),
            fullBodyBytes: 5_000_000
        )
        let flow = Flow(
            id: UUID(),
            request: CapturedRequest(method: "GET", url: "https://api.test/x", headers: []),
            startedAt: Date(),
            outcome: .completed(capped, at: Date())
        ).evictingBodies()

        #expect(flow.response?.body == nil)
        #expect(flow.response?.fullBodyBytes == 5_000_000)
    }

    /// A flow that genuinely had no body must not come back claiming a truncated one.
    @Test func anEmptyBodyIsNotMarkedTruncated() {
        let flow = Flow(
            id: UUID(),
            request: CapturedRequest(method: "GET", url: "https://api.test/x", headers: []),
            startedAt: Date(),
            outcome: .completed(CapturedResponse(statusCode: 204, headers: []), at: Date())
        ).evictingBodies()

        #expect(flow.response?.fullBodyBytes == nil)
        #expect(flow.request.isBodyTruncated == false)
    }

    /// With a store the drop is a *move*, not a loss — so it must stay unflagged, and
    /// the bytes must still come back.
    @Test func withAStoreTheDropStaysRecoverableAndUnflagged() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("loom-budget-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let persistence = try #require(FlowPersistence(fileURL: dir.appendingPathComponent("flows.sqlite")))
        let store = FlowStore(capacity: 100, bodyBudget: 50_000, persistence: persistence)

        let first = flow(0, bodyBytes: 20_000)
        await store.upsert(first)
        for n in 1..<20 { await store.upsert(flow(n, bodyBytes: 20_000)) }
        await store.flush()

        let slimmed = try #require(await store.recent(limit: 100).first { $0.id == first.id })
        #expect(slimmed.response?.body == nil, "slimmed out of the ring")
        #expect(slimmed.bodiesEvicted == nil, "not a loss: the bytes are on disk")
        #expect(slimmed.response?.isBodyTruncated == false, "and so not a truncated capture")

        let hydrated = try #require(await store.flow(id: first.id))
        #expect(hydrated.response?.body?.count == 20_000, "read back on demand")
    }
}
