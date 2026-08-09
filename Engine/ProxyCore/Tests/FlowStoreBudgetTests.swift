import Testing
import Foundation
@testable import LoomProxyCore
import LoomSharedModels

/// Layer 2 of large-body governance: the ring's byte budget. Over budget, the
/// oldest *persisted* flows' bodies are dropped from memory (safe on disk,
/// re-attached on a detail read); in-flight and unbacked flows are never slimmed.
@Suite final class FlowStoreBudgetTests {
    private let fileURL: URL

    init() {
        fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("loom-budget-\(UUID())", isDirectory: true)
            .appendingPathComponent("flows.sqlite")
    }

    deinit {
        try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent())
    }

    private func completed(_ n: Int, bodySize: Int) -> Flow {
        Flow(
            id: UUID(),
            request: CapturedRequest(method: "GET", url: "https://api.test/\(n)", headers: []),
            startedAt: Date(timeIntervalSince1970: TimeInterval(n)),
            outcome: .completed(
                CapturedResponse(statusCode: 200, headers: [], body: Data(count: bodySize)),
                at: Date(timeIntervalSince1970: TimeInterval(n) + 0.1)
            )
        )
    }

    private func pending(_ n: Int, requestBodySize: Int) -> Flow {
        Flow(
            id: UUID(),
            request: CapturedRequest(method: "POST", url: "https://api.test/\(n)", headers: [], body: Data(count: requestBodySize)),
            startedAt: Date(timeIntervalSince1970: TimeInterval(n)),
            outcome: .pending
        )
    }

    @Test func overBudget_slimsOldestCompleted_butHydratesOnDetail() async throws {
        let persistence = try #require(FlowPersistence(fileURL: fileURL))
        let store = FlowStore(capacity: 100, bodyBudget: 1000, persistence: persistence)
        let a = completed(1, bodySize: 600)
        let b = completed(2, bodySize: 600)
        let c = completed(3, bodySize: 600) // inserting c pushes total to 1800 > 1000
        await store.upsert(a)
        await store.upsert(b)
        await store.upsert(c)

        // Oldest survivors were slimmed until under budget; newest keeps its body.
        let ring = await store.recent(limit: 100) // newest-first, ring copies (not hydrated)
        #expect(ring.first(where: { $0.id == a.id })?.response?.body == nil, "oldest slimmed")
        #expect(ring.first(where: { $0.id == b.id })?.response?.body == nil, "next-oldest slimmed")
        #expect(ring.first(where: { $0.id == c.id })?.response?.body?.count == 600, "newest retained")

        // A slimmed flow still hydrates its body from disk on a detail read.
        let detailedA = await store.flow(id: a.id)
        #expect(detailedA?.response?.body?.count == 600, "slimmed body re-attached from disk")
    }

    /// The budget scan starts from a cursor past the leading already-slimmed run
    /// (re-walking the ring per upsert was O(ring) at steady state). The cursor
    /// must pull back when an upsert re-attaches bodies behind it — a WebSocket
    /// frame landing on an old flow — or those bytes become unreclaimable.
    @Test func bodyReattachedBehindTheCursor_isSlimmedAgain() async throws {
        let persistence = try #require(FlowPersistence(fileURL: fileURL))
        let store = FlowStore(capacity: 100, bodyBudget: 1000, persistence: persistence)
        let a = completed(1, bodySize: 600)
        let b = completed(2, bodySize: 600)
        let c = completed(3, bodySize: 600)
        await store.upsert(a) // slimmed by c's arrival…
        await store.upsert(b)
        await store.upsert(c) // …cursor now sits past a and b

        // Re-attach a body to the oldest flow (behind the cursor), then push the
        // total over budget again.
        var fatA = a
        fatA.outcome = .completed(
            CapturedResponse(statusCode: 200, headers: [], body: Data(count: 600)),
            at: Date(timeIntervalSince1970: 1.2)
        )
        await store.upsert(fatA)
        await store.upsert(completed(4, bodySize: 600))

        let ring = await store.recent(limit: 100)
        #expect(ring.first(where: { $0.id == a.id })?.response?.body == nil,
                "the re-attached body behind the cursor was reclaimed")
        #expect(ring.first(where: { $0.id == c.id })?.response?.body == nil, "scan continued past the cursor")
    }

    @Test func underBudget_keepsAllBodies() async throws {
        let persistence = try #require(FlowPersistence(fileURL: fileURL))
        let store = FlowStore(capacity: 100, bodyBudget: 10_000, persistence: persistence)
        let a = completed(1, bodySize: 600)
        await store.upsert(a)
        let kept = await store.recent(limit: 1).first
        #expect(kept?.response?.body?.count == 600)
    }

    @Test func inFlightNotSlimmed_evenOverBudget() async throws {
        let persistence = try #require(FlowPersistence(fileURL: fileURL))
        let store = FlowStore(capacity: 100, bodyBudget: 100, persistence: persistence)
        let p = pending(1, requestBodySize: 600) // 600 > 100 budget, but not persisted
        await store.upsert(p)
        // Its body isn't on disk (in-flight), so slimming it would lose it — kept.
        let kept = await store.recent(limit: 1).first
        #expect(kept?.request.body?.count == 600)
    }

    /// **This test used to assert the opposite**, and the reversal is the point.
    ///
    /// It read: "without a store there's nothing to hydrate back from, so bodies stay
    /// put even over budget (memory pressure is preferable to data loss)." The premise
    /// is right and the conclusion doesn't follow — *unbounded* memory pressure is not
    /// preferable to anything, and that is what it bought: an embedder running
    /// `ProxyEngine(persistFlows: false)` had no body bound at all. Measured on a
    /// 20 000-flow ring with 32 KB bodies, **625 MB live**, against 61 MB for the same
    /// traffic with a store. "Bound what's in memory" has no exception clause.
    ///
    /// So the drop happens, and the data loss the old comment feared is answered by
    /// *recording* it (`bodiesEvicted` + `fullBodyBytes`) rather than by not bounding
    /// anything. `RingBodyBudgetWithoutStoreTests` covers the recording; this pins the
    /// bound.
    @Test func noPersistence_stillHonoursTheBudget_andSaysWhatItDropped() async {
        let store = FlowStore(capacity: 100, bodyBudget: 100)
        await store.upsert(completed(1, bodySize: 600))
        await store.upsert(completed(2, bodySize: 600)) // the cursor only slims behind it

        let oldest = await store.recent(limit: 2).last
        #expect(oldest?.response?.body == nil, "over budget with no store: dropped, not kept")
        #expect(oldest?.bodiesEvicted == true, "and dropped irrecoverably, which is a different fact")
        #expect(oldest?.response?.fullBodyBytes == 600, "with the size that flowed, so no reader thinks it was empty")
    }
}
