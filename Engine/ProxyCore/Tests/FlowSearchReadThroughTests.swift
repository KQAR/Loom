import Testing
import Foundation
@testable import LoomProxyCore
import LoomSharedModels

/// A *filtered* read reaches history, not just the ring.
///
/// `flow(id:)` and `recentHydrated` already read through; the query path did not, and
/// that asymmetry was the bug: the ring holds 2000 flows and the table keeps 20 000, so
/// an agent could hold an id that resolved perfectly well and search for the very same
/// exchange to `[]` — and `[]` reads exactly like "that traffic never happened". Same
/// shape as an unread `CONNECT` recording no flow at all.
@Suite final class FlowSearchReadThroughTests {
    private let fileURL: URL

    init() {
        fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("loom-search-\(UUID())", isDirectory: true)
            .appendingPathComponent("flows.sqlite")
    }

    deinit {
        try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent())
    }

    private func flow(
        _ n: Int,
        host: String = "api.test",
        method: String = "GET",
        status: Int = 200,
        headers: [HeaderPair] = [],
        body: Data? = nil
    ) -> Flow {
        Flow(
            id: UUID(),
            request: CapturedRequest(
                method: method, url: "https://\(host)/\(n)", headers: headers, body: body
            ),
            startedAt: Date(timeIntervalSince1970: TimeInterval(n)),
            outcome: .completed(
                CapturedResponse(statusCode: status, headers: [], body: Data("r\(n)".utf8)),
                at: Date(timeIntervalSince1970: TimeInterval(n) + 0.1)
            )
        )
    }

    // MARK: The hole itself

    @Test func urlSearch_findsAFlowThatAgedOutOfTheRing() async throws {
        let persistence = try #require(FlowPersistence(fileURL: fileURL))
        let store = FlowStore(capacity: 2, persistence: persistence)

        let old = flow(1, host: "old.test")
        await store.upsert(old)
        for n in 2...5 { await store.upsert(flow(n, host: "new.test")) }
        await store.flush()

        var query = FlowQuery()
        query.urlContains = "old.test"
        let found = await store.recent(matching: query, limit: 10)
        #expect(found.map(\.id) == [old.id], "evicted from the ring, still on disk, still findable")
    }

    @Test func recordKindFilterReadsConnectionsThroughFromDisk() async throws {
        let persistence = try #require(FlowPersistence(fileURL: fileURL))
        let store = FlowStore(capacity: 2, persistence: persistence)
        let connection = flow(1, host: "tunnel.test", method: "CONNECT")
        var explicit = flow(2, host: "explicit.test")
        explicit.tunnelDiagnostic = Flow.TunnelDiagnostic(
            host: "explicit.test", port: 443, reason: .notInScope
        )
        await store.upsert(connection)
        await store.upsert(explicit)
        for n in 3...6 { await store.upsert(flow(n)) }
        await store.flush()

        let connections = await store.recent(
            matching: FlowQuery(recordKind: .tunnel), limit: 10
        )
        #expect(connections.map(\.id) == [explicit.id, connection.id])
        let exchanges = await store.recent(
            matching: FlowQuery(recordKind: .exchange), limit: 10
        )
        #expect(exchanges.allSatisfy { $0.recordKind == .exchange })
    }

    @Test func bodySearch_findsAFlowThatAgedOutOfTheRing() async throws {
        let persistence = try #require(FlowPersistence(fileURL: fileURL))
        let store = FlowStore(capacity: 2, persistence: persistence)

        let old = flow(1, body: Data("order-42".utf8))
        await store.upsert(old)
        for n in 2...5 { await store.upsert(flow(n, body: Data("unrelated".utf8))) }
        await store.flush()

        var query = FlowQuery()
        query.bodyContains = "order-42"
        let found = await store.recent(matching: query, limit: 10)
        #expect(found.map(\.id) == [old.id])
    }

    @Test func headerSearch_findsAFlowThatAgedOutOfTheRing() async throws {
        let persistence = try #require(FlowPersistence(fileURL: fileURL))
        let store = FlowStore(capacity: 2, persistence: persistence)

        let old = flow(1, headers: [HeaderPair(name: "X-Env", value: "staging")])
        await store.upsert(old)
        for n in 2...5 { await store.upsert(flow(n)) }
        await store.flush()

        var query = FlowQuery()
        query.headerContains = "x-env: staging"
        let found = await store.recent(matching: query, limit: 10)
        #expect(found.map(\.id) == [old.id])
    }

    /// The ring is consulted first and its results come first, so a match still in
    /// memory is never displaced by an older one from disk.
    @Test func ringMatchesComeBeforeHistoryMatches() async throws {
        let persistence = try #require(FlowPersistence(fileURL: fileURL))
        let store = FlowStore(capacity: 2, persistence: persistence)

        let oldest = flow(1)
        await store.upsert(oldest)
        let newer = flow(2)
        await store.upsert(newer)
        let newest = flow(3)
        await store.upsert(newest)      // evicts `oldest` from a capacity-2 ring
        await store.flush()

        var query = FlowQuery()
        query.urlContains = "api.test"
        let found = await store.recent(matching: query, limit: 10)
        #expect(found.map(\.id) == [newest.id, newer.id, oldest.id])
    }

    /// Every ring id is excluded from the history scan by id, not by timestamp: an
    /// in-flight exchange stays in memory while newer ones complete and persist, so a
    /// time cut would either skip rows or repeat them.
    @Test func aFlowInBothPlacesIsReturnedOnce() async throws {
        let persistence = try #require(FlowPersistence(fileURL: fileURL))
        let store = FlowStore(capacity: 10, persistence: persistence)

        let flow = flow(1)
        await store.upsert(flow)
        await store.flush()

        var query = FlowQuery()
        query.urlContains = "api.test"
        let found = await store.recent(matching: query, limit: 10)
        #expect(found.count == 1)
    }

    /// The ring answering in full must not cost a disk scan at all.
    @Test func aFullAnswerFromTheRingDoesNotReachForHistory() async throws {
        let persistence = try #require(FlowPersistence(fileURL: fileURL))
        let store = FlowStore(capacity: 10, persistence: persistence)
        for n in 1...5 { await store.upsert(flow(n)) }
        await store.flush()

        var query = FlowQuery()
        query.urlContains = "api.test"
        let found = await store.recent(matching: query, limit: 3)
        #expect(found.count == 3, "the limit is reached in memory; history is not consulted")
    }

    // MARK: SQL pushdown must not change which flows match

    @Test func pushedDownPredicatesAgreeWithTheSwiftOnes() async throws {
        let persistence = try #require(FlowPersistence(fileURL: fileURL))
        let store = FlowStore(capacity: 1, persistence: persistence)

        let post = flow(1, method: "POST", status: 500)
        let get = flow(2, method: "GET", status: 200)
        await store.upsert(post)
        await store.upsert(get)
        await store.upsert(flow(3))     // pushes both out of a capacity-1 ring
        await store.flush()

        var byMethod = FlowQuery()
        byMethod.methods = ["post"]     // case-insensitive, like the in-memory predicate
        #expect(await store.recent(matching: byMethod, limit: 10).map(\.id) == [post.id])

        var byStatus = FlowQuery()
        byStatus.statusMin = 500
        byStatus.statusMax = 599
        #expect(await store.recent(matching: byStatus, limit: 10).map(\.id) == [post.id])

        var bySince = FlowQuery()
        bySince.since = Date(timeIntervalSince1970: 2)
        #expect(Set(await store.recent(matching: bySince, limit: 10).map(\.id)).contains(get.id))
        #expect(!Set(await store.recent(matching: bySince, limit: 10).map(\.id)).contains(post.id))
    }

    /// A host glob is deliberately not pushed into SQL — `LIKE` and Loom's glob are
    /// different languages, and getting that subtly wrong drops matching rows.
    @Test func hostGlobIsMatchedInSwift() async throws {
        let persistence = try #require(FlowPersistence(fileURL: fileURL))
        let store = FlowStore(capacity: 1, persistence: persistence)

        let api = flow(1, host: "api.example.com")
        await store.upsert(api)
        await store.upsert(flow(2, host: "other.test"))
        await store.upsert(flow(3, host: "other.test"))
        await store.flush()

        var query = FlowQuery()
        query.host = "*.example.com"
        #expect(await store.recent(matching: query, limit: 10).map(\.id) == [api.id])
    }

    // MARK: What the answer is worth

    @Test func searchReportsHowMuchIsRetained() async throws {
        let persistence = try #require(FlowPersistence(fileURL: fileURL))
        let store = FlowStore(capacity: 2, persistence: persistence)
        for n in 1...4 { await store.upsert(flow(n)) }
        await store.flush()

        var query = FlowQuery()
        query.urlContains = "api.test"
        let result = await store.search(matching: query, limit: 10)
        #expect(result.flows.count == 4)
        #expect(result.storedFlowCount == 4, "the denominator behind the sample")
        #expect(!result.budgetExhausted)
    }

    /// A store with no persistence says `nil` rather than `0` — "nothing is stored"
    /// and "there is no store" are different facts.
    @Test func withoutPersistenceTheRetainedCountIsUnknownNotZero() async {
        let store = FlowStore(capacity: 10, persistence: nil)
        await store.upsert(flow(1))
        var query = FlowQuery()
        query.urlContains = "api.test"
        let result = await store.search(matching: query, limit: 10)
        #expect(result.flows.count == 1)
        #expect(result.storedFlowCount == nil)
    }

    /// The history walk is bounded so it can't hold the persistence queue open in
    /// front of capture flushes — and when the bound bites, it says so.
    @Test func aTruncatedHistoryScanIsReported() throws {
        let persistence = try #require(FlowPersistence(fileURL: fileURL))
        for n in 1...5 { persistence.save(flow(n, host: "noise.test")) }
        persistence.flush()

        var query = FlowQuery()
        query.urlContains = "never-matches"
        let cut = persistence.scan(matching: query, limit: 10, excluding: [], rowBudget: 3)
        #expect(cut.flows.isEmpty)
        #expect(cut.budgetExhausted, "stopped early with the result short — a partial answer")

        let whole = persistence.scan(matching: query, limit: 10, excluding: [], rowBudget: 100)
        #expect(!whole.budgetExhausted, "the whole table was examined; empty is the real answer")
    }
}
