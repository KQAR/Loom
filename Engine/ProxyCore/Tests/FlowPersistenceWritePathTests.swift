import Testing
import Foundation
@testable import LoomProxyCore
import LoomSharedModels

/// The write path is on the capture hot path: every completed flow lands here.
/// It used to re-`prepare` a statement per row, run each row as its own
/// transaction, and execute a full `ORDER BY startedAt` prune scan *per write*.
/// Batching those makes the behaviour observable only through the guarantees
/// pinned here — a save must still be visible to the very next read, the cap must
/// still hold, and a quit must not lose a batch still inside its window.
@Suite("Flow persistence write path", .timeLimit(.minutes(1)))
final class FlowPersistenceWritePathTests {
    private let fileURL: URL

    init() {
        fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("loom-writepath-\(UUID())", isDirectory: true)
            .appendingPathComponent("flows.sqlite")
    }

    deinit {
        try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent())
    }

    private func flow(_ n: Int) -> Flow {
        Flow(
            id: UUID(),
            request: CapturedRequest(method: "GET", url: "https://api.test/\(n)", headers: []),
            startedAt: Date(timeIntervalSince1970: TimeInterval(n)),
            outcome: .completed(
                CapturedResponse(statusCode: 200, headers: [], body: Data("body\(n)".utf8)),
                at: Date(timeIntervalSince1970: TimeInterval(n) + 0.1)
            )
        )
    }

    /// Batching must be invisible: a read drains anything still queued rather than
    /// returning a view that's missing the rows just written.
    @Test func saveThenImmediateRead_seesTheRow() throws {
        let store = try #require(FlowPersistence(fileURL: fileURL))
        let saved = flow(1)
        store.save(saved)
        #expect(store.recent(limit: 10).count == 1, "a batched save must be visible to the next read")
        #expect(store.flow(id: saved.id) != nil)
        #expect(store.bodies(id: saved.id)?.response == Data("body1".utf8))
    }

    @Test func batchOfManySaves_allLand_inOrder() throws {
        let store = try #require(FlowPersistence(fileURL: fileURL))
        for index in 1 ... 300 { store.save(flow(index)) }
        let recent = store.recent(limit: 500)
        #expect(recent.count == 300)
        #expect(recent.first?.request.url == "https://api.test/300", "newest first")
        #expect(recent.last?.request.url == "https://api.test/1")
    }

    /// The prune now runs on a counter rather than on every write; the cap must
    /// still be enforced, and the survivors must be the newest.
    @Test func rowCap_isEnforced_droppingOldest() throws {
        let store = try #require(FlowPersistence(fileURL: fileURL, maxRows: 10, pruneSlack: 0))
        for index in 1 ... 600 { store.save(flow(index)) }
        let recent = store.recent(limit: 1_000)
        #expect(recent.count <= 10, "the cap holds (got \(recent.count))")
        #expect(recent.first?.request.url == "https://api.test/600", "the newest survive")
    }

    /// With slack, the file is allowed to drift above the cap between prunes — but
    /// only by the slack, never unboundedly. This is the cost of not scanning per
    /// write, and it is stated rather than assumed.
    @Test func rowCap_withSlack_staysWithinCapPlusSlack() throws {
        let store = try #require(FlowPersistence(fileURL: fileURL, maxRows: 10, pruneSlack: 100))
        for index in 1 ... 2_000 { store.save(flow(index)) }
        let count = store.recent(limit: 5_000).count
        #expect(count <= 110, "bounded by cap + slack (got \(count))")
    }

    /// A reopened store must re-anchor its row count from the file, or the first
    /// prune after a relaunch would be mis-timed.
    @Test func capHolds_acrossReopen() throws {
        do {
            let store = try #require(FlowPersistence(fileURL: fileURL, maxRows: 10, pruneSlack: 0))
            for index in 1 ... 600 { store.save(flow(index)) }
            store.flush()
        }
        let reopened = try #require(FlowPersistence(fileURL: fileURL, maxRows: 10, pruneSlack: 0))
        for index in 601 ... 1_200 { reopened.save(flow(index)) }
        let recent = reopened.recent(limit: 1_000)
        #expect(recent.count <= 10)
        #expect(recent.first?.request.url == "https://api.test/1200")
    }

    /// `flush()` is what the terminate handler relies on: rows still inside the
    /// batch window must reach the file, not die with the process.
    @Test func flush_drainsAPendingBatch() throws {
        do {
            let store = try #require(FlowPersistence(fileURL: fileURL))
            store.save(flow(1))
            store.save(flow(2))
            store.flush()
        }
        let reopened = try #require(FlowPersistence(fileURL: fileURL))
        #expect(reopened.recent(limit: 10).count == 2)
    }

    /// Dropping the store without an explicit flush must not lose a batch either.
    ///
    /// Polled rather than read once: `save` hands the row to a serial queue, and the
    /// last release (hence `deinit`, hence the flush) happens whenever that closure
    /// finishes — so "has it landed yet" is genuinely asynchronous. The assertion is
    /// "it lands", not "it has already landed by the next statement".
    @Test func deinit_writesAPendingBatch() async throws {
        do {
            let store = try #require(FlowPersistence(fileURL: fileURL))
            store.save(flow(1))
        } // release here; deinit flushes once the queued save has run
        let reopened = try #require(FlowPersistence(fileURL: fileURL))

        var count = 0
        for _ in 0 ..< 200 {
            count = reopened.recent(limit: 10).count
            if count == 1 { break }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        #expect(count == 1, "a batch pending at release must still reach the file")
    }

    @Test func deleteAll_discardsPendingRowsToo() throws {
        let store = try #require(FlowPersistence(fileURL: fileURL))
        store.save(flow(1))
        store.deleteAll()
        #expect(store.recent(limit: 10).isEmpty)
        // And the store keeps working afterwards.
        store.save(flow(2))
        #expect(store.recent(limit: 10).count == 1)
    }

    /// Re-saving the same flow (the finalize-on-quit path) must update, not
    /// duplicate — the insert is an upsert on the id primary key.
    @Test func resavingSameID_updatesRatherThanDuplicates() throws {
        let store = try #require(FlowPersistence(fileURL: fileURL))
        var subject = flow(1)
        store.save(subject)
        subject.outcome = .failed(FlowError("interrupted"), at: Date(timeIntervalSince1970: 2), partialResponse: nil)
        store.save(subject)
        let recent = store.recent(limit: 10)
        #expect(recent.count == 1)
        #expect(recent.first?.error == "interrupted")
    }
}
