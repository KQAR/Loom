import Foundation
import Testing
import LoomSharedModels
@testable import LoomProxyCore

/// A filtered read must not stall capture.
///
/// `FlowStore` is one actor and everything queues on it: every exchange upserts at
/// least twice (pending → completed), a streaming one more, a WebSocket once per
/// frame. `recent(matching:)` used to run its scan *there* — 2.1 ms over a full
/// ring — so an agent polling `get_recent_flows` with a filter put that stall in
/// front of every capture write. Measured before the fix, on an idle M-series Mac:
///
/// | | |
/// |---|---|
/// | one host-filtered scan over 2000 flows | 2.1 ms |
/// | one upsert, quiet | 0.014 ms |
/// | one upsert, while scans run | 1.8 ms (**127×**) |
///
/// The scan now runs off the actor over a snapshot of the ring — free, because an
/// `Array` of value types is COW — and the contended upsert is back to 0.015 ms.
///
/// This test is a timing assertion, which the rest of this suite avoids; the
/// property genuinely is "how long does a write wait", and there is no structural
/// stand-in for it. The bound is set where a regression is unmistakable rather than
/// where the measurement sits: 0.5 ms is 30× the real cost and 3.5× *under* the
/// broken one, so a loaded CI runner has room and a scan moving back onto the actor
/// does not.
@Suite struct FlowStoreScanContentionTests {
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

    @Test func aFilteredReadDoesNotBlockCaptureWrites() async {
        let store = FlowStore(capacity: 2000)
        for i in 0 ..< 2000 { await store.upsert(flow(i)) }

        var query = FlowQuery()
        query.host = "host7.example.test"

        // A scan loop hammering the store for the whole of the measurement below.
        let scanning = Task {
            while !Task.isCancelled { _ = await store.recent(matching: query, limit: 20) }
        }
        defer { scanning.cancel() }

        let contended = await medianUpsertMS(store, from: 100_000, count: 200)
        #expect(
            contended < 0.5,
            """
            An upsert took \(contended) ms while filtered reads were running. That is the \
            shape of the scan holding the actor: capture writes queue behind it, and every \
            exchange performs several. Check that `recent(matching:)` still hands its work \
            to the off-actor `scan`.
            """
        )
    }

    /// The HAR export's read, which hydrates every match from disk: the scan and the
    /// blob reads both run off the actor, so a big filtered export is not a stall in
    /// front of capture either.
    ///
    /// Sampled on a wall-clock cadence rather than back to back, unlike the test above.
    /// One export holds the actor for tens of milliseconds when it is wrong, and a
    /// tight loop of upserts lands almost all of its samples in the gaps between
    /// exports — measured, moving the hydration onto the actor left a back-to-back
    /// median at 0.004 ms. A sample every millisecond hits a busy actor in proportion
    /// to how long it is busy: measured here, **0.008 ms** off the actor against
    /// **7.5 ms** with the hydration moved back onto it.
    @Test func aFilteredExportDoesNotBlockCaptureWrites() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("loom-export-contention-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let persistence = try #require(FlowPersistence(fileURL: directory.appendingPathComponent("flows.sqlite")))
        // Rows read from disk arrive with their bodies; what the export hydrates is the
        // ring's flows the 64 MB body budget slimmed. At 128 KB each it keeps ~500, so
        // ~700 of these are blob reads.
        let store = FlowStore(capacity: 2000, persistence: persistence)
        let body = Data(repeating: 0x61, count: 128 * 1024)
        for i in 0 ..< 1200 {
            var flow = flow(i)
            flow.outcome = .completed(CapturedResponse(statusCode: 200, headers: [], body: body), at: Date())
            await store.upsert(flow)
        }
        await store.flush()

        var query = FlowQuery()
        query.host = "*.example.test"
        let exporting = Task {
            while !Task.isCancelled { _ = await store.searchHydrated(matching: query, limit: 1000) }
        }
        defer { exporting.cancel() }

        var samples: [Double] = []
        for i in 0 ..< 150 {
            try await Task.sleep(for: .milliseconds(1))
            let flow = flow(100_000 + i)
            let started = DispatchTime.now().uptimeNanoseconds
            await store.upsert(flow)
            samples.append(Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000)
        }
        let contended = samples.sorted()[samples.count / 2]
        #expect(
            contended < 0.5,
            "An upsert took \(contended) ms while filtered exports ran — the export's scan or hydration is holding the actor."
        )
    }

    /// The scan must return the same flows it always did — the snapshot is a COW
    /// reference to the ring as of the call, not a relaxation of what "matching" means.
    @Test func theOffActorScanSeesTheRingAsOfTheCall() async {
        let store = FlowStore(capacity: 100)
        for i in 0 ..< 20 { await store.upsert(flow(i)) }

        var query = FlowQuery()
        query.host = "host7.example.test"
        let before = await store.recent(matching: query, limit: 50)
        #expect(!before.isEmpty)
        #expect(before.allSatisfy { $0.request.url.contains("host7.example.test") })
        // Newest-first, like every other read.
        #expect(before == before.sorted { $0.startedAt > $1.startedAt })

        // A flow added after the read is not in it, and is in the next one.
        await store.upsert(flow(107))
        let after = await store.recent(matching: query, limit: 50)
        #expect(after.count == before.count + 1)
    }
}
