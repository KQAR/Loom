import Testing
import Foundation
@testable import LoomProxyCore
import LoomSharedModels

/// "How many flows are retained" must not stall capture.
///
/// Sibling of `FlowStoreScanContentionTests`, and the same defect one layer down. That
/// one was a *scan* holding the `FlowStore` actor; this one was a **count**, which is
/// worse for being so obviously cheap that nobody looked: `FlowPersistence.storedRowCount`
/// opened with `queue.sync { writePending() }`, so reading a number forced a synchronous
/// SQLite transaction of up to `maxBatch` rows — on the persistence queue that batched
/// writes flush on, while holding the actor every capture write queues on.
///
/// The caller that makes it matter is `ProxyEngine.status()` (via `FlowStore.retainedCount`),
/// which is not a rare read: the window's audit fan-out re-reads it after every agent
/// write, `.viewAppeared` reads it on every panel open, and `get_proxy_status` is a poll
/// the skill actively encourages an agent to make. `FlowStore.search` and
/// `page`'s `totalRetained()` had the same shape.
///
/// The count is now mirrored out of the queue (`approximateStoredRowCount`), pending rows
/// included — which is what the drain was buying — so the read costs a lock acquire.
@Suite final class RetainedCountContentionTests {
    private let fileURL: URL

    init() {
        fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("loom-retainedcount-\(UUID())", isDirectory: true)
            .appendingPathComponent("flows.sqlite")
    }

    deinit {
        try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent())
    }

    private func flow(_ i: Int) -> Flow {
        var flow = Flow(
            request: CapturedRequest(
                method: "GET",
                url: "https://host\(i % 50).example.test/v1/path/\(i)",
                headers: [HeaderPair(name: "Accept", value: "application/json")]
            ),
            startedAt: Date()
        )
        flow.outcome = .completed(CapturedResponse(statusCode: 200, headers: []), at: Date())
        return flow
    }

    /// Milliseconds, median of `count` upserts.
    private func medianUpsertMS(_ store: FlowStore, from seed: Int, count: Int) async -> Double {
        var samples: [Double] = []
        samples.reserveCapacity(count)
        for i in 0 ..< count {
            let flow = flow(seed + i)
            let started = DispatchTime.now().uptimeNanoseconds
            await store.upsert(flow)
            samples.append(Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000)
        }
        return samples.sorted()[samples.count / 2]
    }

    /// The timing assertion, with the same reasoning as `FlowStoreScanContentionTests`:
    /// the property genuinely is "how long does a write wait", and there is no structural
    /// stand-in. The bound is set where a regression is unmistakable rather than at the
    /// measurement — a lock acquire is microseconds, and a synchronous batch transaction
    /// is orders above this.
    @Test func readingTheRetainedCountDoesNotBlockCaptureWrites() async throws {
        let persistence = try #require(FlowPersistence(fileURL: fileURL))
        let store = FlowStore(capacity: 2000, persistence: persistence)
        for i in 0 ..< 500 { await store.upsert(flow(i)) }

        // A `status()`-shaped read loop, hammering the store for the whole measurement.
        let counting = Task {
            while !Task.isCancelled { _ = await store.retainedCount }
        }
        defer { counting.cancel() }

        let contended = await medianUpsertMS(store, from: 100_000, count: 200)
        #expect(
            contended < 1.0,
            """
            An upsert took \(contended) ms while the retained count was being read. That is \
            the shape of the count entering the persistence queue: it drains the pending \
            batch inside a `queue.sync` while holding the FlowStore actor, so every capture \
            write queues behind a SQLite transaction. Check that `FlowStore.retainedCount` \
            still reads `FlowPersistence.approximateStoredRowCount`.
            """
        )
    }

    /// The count must still include rows that are saved but not yet written, because
    /// that is exactly what the drain used to buy. Without it the answer lags a whole
    /// batch window behind the capture, and a paged list is short by the page it is
    /// currently looking at.
    @Test func theCountIncludesRowsStillInTheBatch() throws {
        let persistence = try #require(FlowPersistence(fileURL: fileURL))
        for i in 1 ... 5 {
            persistence.save(
                Flow(
                    id: UUID(),
                    request: CapturedRequest(method: "GET", url: "https://api.test/\(i)", headers: []),
                    startedAt: Date(timeIntervalSince1970: TimeInterval(i)),
                    outcome: .completed(
                        CapturedResponse(statusCode: 200, headers: []),
                        at: Date(timeIntervalSince1970: TimeInterval(i) + 0.1)
                    )
                )
            )
        }
        // Deliberately no `flush()`: the rows are inside their batch window, which is the
        // state the drain existed to paper over.
        //
        // Polled rather than read once — `save` hands the row to the queue, so "has it
        // been counted" is genuinely asynchronous. The assertion is that it converges to
        // 5 without a drain, not that it is 5 on the next line.
        var count = 0
        for _ in 0 ..< 200 {
            count = persistence.approximateStoredRowCount
            if count == 5 { break }
            usleep(5_000)
        }
        #expect(count == 5, "pending rows are counted (got \(count))")

        // And the number does not double when the batch lands.
        persistence.flush()
        #expect(persistence.approximateStoredRowCount == 5, "a written row is counted once, not twice")
    }

    @Test func theCountFollowsADeleteAll() throws {
        let persistence = try #require(FlowPersistence(fileURL: fileURL))
        persistence.save(
            Flow(
                id: UUID(),
                request: CapturedRequest(method: "GET", url: "https://api.test/1", headers: []),
                startedAt: Date(timeIntervalSince1970: 1),
                outcome: .completed(CapturedResponse(statusCode: 200, headers: []), at: Date(timeIntervalSince1970: 2))
            )
        )
        persistence.flush()
        #expect(persistence.approximateStoredRowCount == 1)

        persistence.deleteAll()
        persistence.flush()
        #expect(persistence.approximateStoredRowCount == 0, "clearing the capture clears the count")
    }

    /// A reopened store re-anchors from the file, so the mirror is not a
    /// process-lifetime accumulator.
    @Test func theCountIsAnchoredOnReopen() throws {
        do {
            let persistence = try #require(FlowPersistence(fileURL: fileURL))
            for i in 1 ... 12 {
                persistence.save(
                    Flow(
                        id: UUID(),
                        request: CapturedRequest(method: "GET", url: "https://api.test/\(i)", headers: []),
                        startedAt: Date(timeIntervalSince1970: TimeInterval(i)),
                        outcome: .completed(
                            CapturedResponse(statusCode: 200, headers: []),
                            at: Date(timeIntervalSince1970: TimeInterval(i) + 0.1)
                        )
                    )
                )
            }
            persistence.flush()
        }
        let reopened = try #require(FlowPersistence(fileURL: fileURL))
        #expect(reopened.approximateStoredRowCount == 12)
    }
}
