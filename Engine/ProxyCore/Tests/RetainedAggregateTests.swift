import Testing
import Foundation
@testable import LoomProxyCore
import LoomSharedModels

/// The sidebar's counts, over everything **retained** rather than over what happens to
/// be in memory.
///
/// They used to be folded by the window, which made every badge a count of the newest
/// 2000 exchanges while the store kept 20 000: a host with 300 flows read 12, and a
/// host whose traffic had all aged out vanished from the sidebar while its rows sat on
/// disk — searchable, and unlisted. Three rules make the engine's version exact, and
/// each is a place the obvious implementation drifts.
@Suite final class RetainedAggregateTests {
    private let fileURL: URL

    init() {
        fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("loom-aggregates-\(UUID())", isDirectory: true)
            .appendingPathComponent("flows.sqlite")
    }

    deinit {
        try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent())
    }

    private func flow(
        _ n: Int, host: String = "api.test", status: Int? = 200, pending: Bool = false
    ) -> Flow {
        let started = Date(timeIntervalSince1970: TimeInterval(n))
        return Flow(
            id: UUID(),
            request: CapturedRequest(method: "GET", url: "https://\(host)/\(n)", headers: []),
            startedAt: started,
            outcome: pending
                ? .pending
                : .completed(CapturedResponse(statusCode: status ?? 200, headers: []), at: started.addingTimeInterval(0.1))
        )
    }

    // MARK: Rule 1 — leaving the ring is not leaving the capture

    @Test func aFlowEvictedFromTheRingIsStillCounted() async throws {
        let persistence = try #require(FlowPersistence(fileURL: fileURL))
        let store = FlowStore(capacity: 5, persistence: persistence)
        for n in 1...50 { await store.upsert(flow(n)) }
        await store.flush()

        let counts = await store.flowAggregates().aggregates
        #expect(counts.hostCounts["api.test"] == 50, "45 of these are only on disk — still retained, still counted")
    }

    /// The exception to rule 1: a flow that never completed was never persisted, so
    /// evicting it really does remove it from everything retained.
    @Test func anInFlightFlowEvictedBeforeCompletingIsRetracted() async throws {
        let persistence = try #require(FlowPersistence(fileURL: fileURL))
        let store = FlowStore(capacity: 3, persistence: persistence)
        await store.upsert(flow(1, host: "stalled.test", pending: true))
        for n in 2...10 { await store.upsert(flow(n)) }
        await store.flush()

        let counts = await store.flowAggregates().aggregates
        #expect(counts.hostCounts["stalled.test"] == nil, "never persisted, now evicted: genuinely gone")
        #expect(counts.hostCounts["api.test"] == 9)
    }

    // MARK: Rule 2 — an upsert re-counts

    @Test func anOutcomeChangeMovesTheErrorCount() async throws {
        let persistence = try #require(FlowPersistence(fileURL: fileURL))
        let store = FlowStore(capacity: 100, persistence: persistence)

        var flow = flow(1, pending: true)
        await store.upsert(flow)
        #expect(await store.flowAggregates().aggregates.errorCount == 0, "pending is not an error")

        flow.outcome = .completed(CapturedResponse(statusCode: 500, headers: []), at: Date())
        await store.upsert(flow)
        #expect(await store.flowAggregates().aggregates.errorCount == 1)

        flow.outcome = .completed(CapturedResponse(statusCode: 200, headers: []), at: Date())
        await store.upsert(flow)
        #expect(await store.flowAggregates().aggregates.errorCount == 0, "and back, without double counting")
        #expect(await store.flowAggregates().aggregates.hostCounts["api.test"] == 1, "one flow, however many upserts")
    }

    // MARK: Rule 3 — the pruner removes rows nobody upserted

    /// The durable store drops its oldest rows on its own schedule. Those flows never
    /// pass back through `upsert`, so without the prune notification the counts would
    /// keep counting them forever and a fully-pruned host would sit in the sidebar with
    /// no rows behind it.
    @Test func prunedRowsAreRetracted() async throws {
        let persistence = try #require(FlowPersistence(fileURL: fileURL, maxRows: 10, pruneSlack: 0))
        let store = FlowStore(capacity: 5, persistence: persistence)
        for n in 1...30 { await store.upsert(flow(n, host: n <= 15 ? "old.test" : "new.test")) }
        await store.flush()

        // The prune hop is a `Task` off the persistence queue; give it a moment to land.
        try await Task.sleep(for: .milliseconds(200))
        let counts = await store.flowAggregates().aggregates
        let total = counts.hostCounts.values.reduce(0, +)
        #expect(total <= 15, "pruned rows stopped being counted (was \(total))")
        #expect(counts.hostCounts["new.test"] != nil, "the surviving host is still there")
    }

    // MARK: Boot

    /// The counts have to cover history a relaunch didn't load into the ring — which is
    /// most of it, since the ring restores at most its own capacity.
    @Test func bootAggregationCoversRowsTheRingDidNotRestore() async throws {
        let persistence = try #require(FlowPersistence(fileURL: fileURL))
        let seeding = FlowStore(capacity: 100, persistence: persistence)
        for n in 1...40 { await seeding.upsert(flow(n)) }
        await seeding.flush()

        // A "relaunch": a fresh store over the same file, restoring a small ring.
        let restarted = FlowStore(capacity: 5, persistence: persistence)
        await restarted.loadPersisted(limit: 5)
        let beforeHistory = await restarted.flowAggregates()
        #expect(beforeHistory.aggregates.hostCounts["api.test"] == 5)
        #expect(!beforeHistory.coversHistory, "and it says so rather than passing 5 off as the total")

        await restarted.seedAggregatesFromHistory()
        let afterHistory = await restarted.flowAggregates()
        #expect(afterHistory.aggregates.hostCounts["api.test"] == 40)
        #expect(afterHistory.coversHistory)
    }

    /// The history pass replaces the counts wholesale, so anything not on disk has to
    /// be folded back in — otherwise a busy boot loses every exchange started since.
    @Test func theHistoryPassKeepsInFlightFlows() async throws {
        let persistence = try #require(FlowPersistence(fileURL: fileURL))
        let store = FlowStore(capacity: 100, persistence: persistence)
        for n in 1...10 { await store.upsert(flow(n)) }
        await store.upsert(flow(11, host: "inflight.test", pending: true))
        await store.flush()

        await store.seedAggregatesFromHistory()
        let counts = await store.flowAggregates().aggregates
        #expect(counts.hostCounts["api.test"] == 10)
        #expect(counts.hostCounts["inflight.test"] == 1, "in flight, not on disk, still retained")
    }

    @Test func clearingResetsTheCounts() async throws {
        let persistence = try #require(FlowPersistence(fileURL: fileURL))
        let store = FlowStore(capacity: 100, persistence: persistence)
        for n in 1...10 { await store.upsert(flow(n)) }
        await store.flush()
        await store.clear()

        let counts = await store.flowAggregates().aggregates
        #expect(counts.hostCounts.isEmpty)
        #expect(counts.errorCount == 0)
    }
}
