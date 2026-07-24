import XCTest
@testable import ProxyCore
import SharedModels

/// Layer 2 of large-body governance: the ring's byte budget. Over budget, the
/// oldest *persisted* flows' bodies are dropped from memory (safe on disk,
/// re-attached on a detail read); in-flight and unbacked flows are never slimmed.
final class FlowStoreBudgetTests: XCTestCase {
    private var fileURL: URL!

    override func setUp() {
        super.setUp()
        fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("loom-budget-\(UUID())", isDirectory: true)
            .appendingPathComponent("flows.sqlite")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent())
        super.tearDown()
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

    func test_overBudget_slimsOldestCompleted_butHydratesOnDetail() async throws {
        let persistence = try XCTUnwrap(FlowPersistence(fileURL: fileURL))
        let store = FlowStore(capacity: 100, bodyBudget: 1000, persistence: persistence)
        let a = completed(1, bodySize: 600)
        let b = completed(2, bodySize: 600)
        let c = completed(3, bodySize: 600) // inserting c pushes total to 1800 > 1000
        await store.upsert(a)
        await store.upsert(b)
        await store.upsert(c)

        // Oldest survivors were slimmed until under budget; newest keeps its body.
        let ring = await store.recent(limit: 100) // newest-first, ring copies (not hydrated)
        XCTAssertNil(ring.first(where: { $0.id == a.id })?.response?.body, "oldest slimmed")
        XCTAssertNil(ring.first(where: { $0.id == b.id })?.response?.body, "next-oldest slimmed")
        XCTAssertEqual(ring.first(where: { $0.id == c.id })?.response?.body?.count, 600, "newest retained")

        // A slimmed flow still hydrates its body from disk on a detail read.
        let detailedA = await store.flow(id: a.id)
        XCTAssertEqual(detailedA?.response?.body?.count, 600, "slimmed body re-attached from disk")
    }

    func test_underBudget_keepsAllBodies() async throws {
        let persistence = try XCTUnwrap(FlowPersistence(fileURL: fileURL))
        let store = FlowStore(capacity: 100, bodyBudget: 10_000, persistence: persistence)
        let a = completed(1, bodySize: 600)
        await store.upsert(a)
        let kept = await store.recent(limit: 1).first
        XCTAssertEqual(kept?.response?.body?.count, 600)
    }

    func test_inFlightNotSlimmed_evenOverBudget() async throws {
        let persistence = try XCTUnwrap(FlowPersistence(fileURL: fileURL))
        let store = FlowStore(capacity: 100, bodyBudget: 100, persistence: persistence)
        let p = pending(1, requestBodySize: 600) // 600 > 100 budget, but not persisted
        await store.upsert(p)
        // Its body isn't on disk (in-flight), so slimming it would lose it — kept.
        let kept = await store.recent(limit: 1).first
        XCTAssertEqual(kept?.request.body?.count, 600)
    }

    func test_noPersistence_neverSlims() async {
        // Without a store there's nothing to hydrate back from, so bodies stay put
        // even over budget (memory pressure is preferable to data loss).
        let store = FlowStore(capacity: 100, bodyBudget: 100)
        let a = completed(1, bodySize: 600)
        await store.upsert(a)
        let kept = await store.recent(limit: 1).first
        XCTAssertEqual(kept?.response?.body?.count, 600)
    }
}
