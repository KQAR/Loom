import Testing
import Foundation
@testable import LoomProxyCore
import LoomSharedModels

/// Keyset paging over ring + history.
///
/// The property that matters is not "a page comes back" — it's that walking every page
/// yields **every flow exactly once, in order**, across the seam between memory and
/// disk and while the capture keeps prepending. Paging bugs don't crash; they drop one
/// row at a boundary or repeat one, which reads as a capture that missed something.
@Suite final class FlowPageTests {
    private let fileURL: URL

    init() {
        fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("loom-page-\(UUID())", isDirectory: true)
            .appendingPathComponent("flows.sqlite")
    }

    deinit {
        try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent())
    }

    /// `at` in whole seconds unless given a fraction, so same-instant collisions can be
    /// forced deliberately.
    private func flow(_ n: Int, at: TimeInterval? = nil, host: String = "api.test", pending: Bool = false) -> Flow {
        let started = Date(timeIntervalSince1970: at ?? TimeInterval(n))
        return Flow(
            id: UUID(),
            request: CapturedRequest(method: "GET", url: "https://\(host)/\(n)", headers: []),
            startedAt: started,
            outcome: pending
                ? .pending
                : .completed(CapturedResponse(statusCode: 200, headers: []), at: started.addingTimeInterval(0.1))
        )
    }

    /// Walk every page and return the ids in the order they came out.
    private func walk(_ store: FlowStore, pageSize: Int, query: FlowQuery = .all) async -> [UUID] {
        var ids: [UUID] = []
        var cursor: FlowCursor?
        var guardCount = 0
        while true {
            let page = await store.page(after: cursor, limit: pageSize, matching: query)
            ids.append(contentsOf: page.flows.map(\.id))
            guard let next = page.nextCursor else { break }
            cursor = next
            guardCount += 1
            #expect(guardCount < 1_000, "paging did not terminate")
            if guardCount >= 1_000 { break }
        }
        return ids
    }

    // MARK: The whole point

    @Test func pagingTheRingYieldsEveryFlowOnceNewestFirst() async throws {
        let persistence = try #require(FlowPersistence(fileURL: fileURL))
        let store = FlowStore(capacity: 100, persistence: persistence)
        var expected: [UUID] = []
        for n in 1...50 {
            let flow = flow(n)
            expected.append(flow.id)
            await store.upsert(flow)
        }
        await store.flush()

        let ids = await walk(store, pageSize: 7)
        #expect(ids == expected.reversed(), "newest-first, every flow once, no seam duplicates")
    }

    /// The case the whole design exists for: most rows are only on disk.
    @Test func pagingCrossesTheSeamIntoHistory() async throws {
        let persistence = try #require(FlowPersistence(fileURL: fileURL))
        let store = FlowStore(capacity: 5, persistence: persistence)   // 45 of 50 evicted
        var expected: [UUID] = []
        for n in 1...50 {
            let flow = flow(n)
            expected.append(flow.id)
            await store.upsert(flow)
        }
        await store.flush()

        let ids = await walk(store, pageSize: 7)
        #expect(ids.count == 50, "history is paged too, not just the ring")
        #expect(ids == expected.reversed())
        #expect(Set(ids).count == 50, "nothing repeated across the seam")
    }

    /// A page boundary landing between two flows captured in the same instant is
    /// exactly where an untiebroken cursor drops one and repeats the other.
    @Test func aPageBoundaryInsideOneInstantIsStable() async throws {
        let persistence = try #require(FlowPersistence(fileURL: fileURL))
        let store = FlowStore(capacity: 3, persistence: persistence)
        var expected: [UUID] = []
        for n in 1...20 {           // every single one at the same startedAt
            let flow = flow(n, at: 1_000)
            expected.append(flow.id)
            await store.upsert(flow)
        }
        await store.flush()

        let ids = await walk(store, pageSize: 3)
        #expect(Set(ids).count == 20, "no flow lost or repeated when the timestamp can't order them")
        #expect(ids == expected.sorted { $0.uuidString > $1.uuidString },
                "ordered by the tiebreak, which is what the cursor seeks in")
    }

    /// Insertion order is only *approximately* `startedAt` order: a long-running
    /// exchange is appended when it starts and completes much later. Walking the ring
    /// by position would skip it.
    @Test func anOldInFlightFlowIsNotSkipped() async throws {
        let persistence = try #require(FlowPersistence(fileURL: fileURL))
        let store = FlowStore(capacity: 100, persistence: persistence)

        let longRunning = flow(1, at: 1, pending: true)  // starts first, never completes
        await store.upsert(longRunning)
        for n in 2...20 { await store.upsert(flow(n, at: TimeInterval(n))) }
        await store.flush()

        let ids = await walk(store, pageSize: 4)
        #expect(ids.count == 20)
        #expect(ids.last == longRunning.id, "oldest by startedAt, so last — and present")
    }

    // MARK: Cursor semantics

    @Test func theLastPageReportsNoCursor() async throws {
        let persistence = try #require(FlowPersistence(fileURL: fileURL))
        let store = FlowStore(capacity: 100, persistence: persistence)
        for n in 1...5 { await store.upsert(flow(n)) }
        await store.flush()

        let page = await store.page(after: nil, limit: 10, matching: .all)
        #expect(page.flows.count == 5)
        #expect(page.nextCursor == nil, "a short page is the end")
    }

    @Test func anEmptyStorePagesToNothing() async throws {
        let persistence = try #require(FlowPersistence(fileURL: fileURL))
        let store = FlowStore(capacity: 100, persistence: persistence)
        let page = await store.page(after: nil, limit: 10, matching: .all)
        #expect(page.flows.isEmpty)
        #expect(page.nextCursor == nil)
        #expect(page.totalCount == 0)
    }

    /// A cursor is a value in the ordering, not a position, so it stays correct when
    /// the capture prepends underneath it — the failure an `OFFSET` would have.
    @Test func newFlowsArrivingMidWalkDoNotShiftThePage() async throws {
        let persistence = try #require(FlowPersistence(fileURL: fileURL))
        let store = FlowStore(capacity: 100, persistence: persistence)
        var original: [UUID] = []
        for n in 1...20 {
            let flow = flow(n)
            original.append(flow.id)
            await store.upsert(flow)
        }
        await store.flush()

        let first = await store.page(after: nil, limit: 5, matching: .all)
        // 10 newer exchanges land between the two page reads.
        for n in 21...30 { await store.upsert(flow(n)) }
        await store.flush()

        let second = await store.page(after: first.nextCursor, limit: 5, matching: .all)
        let expectedSecond = Array(original.reversed()[5..<10])
        #expect(second.flows.map(\.id) == expectedSecond,
                "the second page continues where the first ended, not five rows into a longer list")
    }

    // MARK: Filters and counts

    @Test func aQueryNarrowsEveryPage() async throws {
        let persistence = try #require(FlowPersistence(fileURL: fileURL))
        let store = FlowStore(capacity: 4, persistence: persistence)
        var wanted: [UUID] = []
        for n in 1...30 {
            let flow = flow(n, host: n % 3 == 0 ? "keep.test" : "drop.test")
            if n % 3 == 0 { wanted.append(flow.id) }
            await store.upsert(flow)
        }
        await store.flush()

        var query = FlowQuery()
        query.host = "keep.test"
        let ids = await walk(store, pageSize: 3, query: query)
        #expect(ids == wanted.reversed(), "the filter applies across the seam, not just in the ring")
    }

    /// `upsert` persists only completed flows, so the stored count plus the ring's
    /// in-flight ones is the total with nothing counted twice.
    @Test func totalCountsEachFlowOnce() async throws {
        let persistence = try #require(FlowPersistence(fileURL: fileURL))
        let store = FlowStore(capacity: 100, persistence: persistence)
        for n in 1...10 { await store.upsert(flow(n)) }         // completed → on disk and in the ring
        await store.upsert(flow(11, pending: true))             // in flight → ring only
        await store.flush()

        let page = await store.page(after: nil, limit: 5, matching: .all)
        #expect(page.totalCount == 11)
    }

    /// Without a store the ring is the whole truth and the caller already has its
    /// count — saying `0` would be a claim, `nil` is the fact.
    @Test func withoutAStoreTheTotalIsUnknown() async {
        let store = FlowStore(capacity: 100, persistence: nil)
        await store.upsert(flow(1))
        let page = await store.page(after: nil, limit: 5, matching: .all)
        #expect(page.flows.count == 1)
        #expect(page.totalCount == nil)
    }

    @Test func aZeroLimitIsNotAnInfiniteLoop() async throws {
        let persistence = try #require(FlowPersistence(fileURL: fileURL))
        let store = FlowStore(capacity: 100, persistence: persistence)
        await store.upsert(flow(1))
        let page = await store.page(after: nil, limit: 0, matching: .all)
        #expect(page.flows.isEmpty)
    }
}
