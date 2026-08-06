import Testing
import Foundation
@testable import LoomProxyCore
import LoomSharedModels

/// The ordering guarantee that makes filtering worth having: the filter runs over
/// everything retained and *then* the limit applies. If it were the other way
/// round (take newest N, filter those), "no matching request" would be
/// indistinguishable from "your match is older than N" — the exact ambiguity that
/// makes an agent conclude a request never happened.
@Suite struct FlowStoreQueryTests {
    private func flow(_ url: String, method: String = "GET", status: Int = 200, at seconds: TimeInterval) -> Flow {
        Flow(
            id: UUID(),
            request: CapturedRequest(method: method, url: url, headers: []),
            startedAt: Date(timeIntervalSince1970: seconds),
            outcome: .completed(CapturedResponse(statusCode: status, headers: []), at: Date(timeIntervalSince1970: seconds))
        )
    }

    @Test func filterScansTheWholeRing_notJustTheNewestLimit() async {
        let store = FlowStore()
        // One interesting flow, then 200 unrelated newer ones.
        await store.upsert(flow("https://api.example.com/orders", method: "POST", status: 500, at: 1))
        for index in 0 ..< 200 {
            await store.upsert(flow("https://cdn.example.com/asset\(index).png", at: Double(index + 2)))
        }

        let unfiltered = await store.recent(limit: 20)
        #expect(!unfiltered.contains { $0.request.url.contains("orders") },
                "precondition: the match is well outside the newest 20")

        let matches = await store.recent(matching: FlowQuery(methods: ["POST"]), limit: 20)
        #expect(matches.count == 1)
        #expect(matches.first?.request.url == "https://api.example.com/orders")
    }

    @Test func resultsStayNewestFirst_andRespectTheLimit() async {
        let store = FlowStore()
        for index in 0 ..< 10 {
            await store.upsert(flow("https://api.example.com/\(index)", status: 500, at: Double(index)))
        }
        let matches = await store.recent(matching: FlowQuery(onlyErrors: true), limit: 3)
        #expect(matches.count == 3)
        #expect(matches.map(\.request.url) == [
            "https://api.example.com/9", "https://api.example.com/8", "https://api.example.com/7",
        ])
    }

    @Test func emptyQuery_matchesThePlainRecentPath() async {
        let store = FlowStore()
        for index in 0 ..< 5 { await store.upsert(flow("https://a/\(index)", at: Double(index))) }
        let plain = await store.recent(limit: 3)
        let queried = await store.recent(matching: .all, limit: 3)
        #expect(plain.map(\.id) == queried.map(\.id))
    }

    @Test func noMatch_isAnEmptyList() async {
        let store = FlowStore()
        await store.upsert(flow("https://a/1", at: 1))
        let matches = await store.recent(matching: FlowQuery(host: "nope.test"), limit: 10)
        #expect(matches.isEmpty)
    }

    /// A body predicate has to see bodies the ring no longer holds — that's the
    /// whole point of searching a capture rather than the newest few exchanges. The
    /// budget here slims every flow the moment it lands, so a naive implementation
    /// (match the ring copy) finds nothing at all.
    @Test func bodyPredicate_findsAFlowWhoseBodyWasSlimmedToDisk() async throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("loom-bodyquery-\(UUID())", isDirectory: true)
            .appendingPathComponent("flows.sqlite")
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
        let persistence = try #require(FlowPersistence(fileURL: fileURL))
        // Budget of 1 byte: bodies live in memory for exactly one upsert.
        let store = FlowStore(capacity: 10, bodyBudget: 1, persistence: persistence)

        let subject = Flow(
            id: UUID(),
            request: CapturedRequest(method: "POST", url: "https://api.example.com/orders", headers: []),
            startedAt: Date(timeIntervalSince1970: 1),
            outcome: .completed(
                CapturedResponse(statusCode: 500, headers: [], body: Data(#"{"error":"INSUFFICIENT_FUNDS"}"#.utf8)),
                at: Date(timeIntervalSince1970: 1.1)
            )
        )
        await store.upsert(subject)
        await store.upsert(flow("https://cdn.example.com/asset.png", at: 2)) // forces the slim

        let ringCopy = await store.recent(limit: 10).first { $0.id == subject.id }
        #expect(ringCopy?.response?.body == nil, "precondition: the ring no longer holds the body")

        let matches = await store.recent(matching: FlowQuery(bodyContains: "insufficient_funds"), limit: 10)
        #expect(matches.map(\.id) == [subject.id])
        #expect(matches.first?.response?.body == nil,
                "a filtered list read still hands back body-free flows (invariant I2)")

        #expect(await store.recent(matching: FlowQuery(bodyContains: "no_such_string"), limit: 10).isEmpty)
    }

    /// A body predicate ANDs with the cheap ones rather than overriding them: a
    /// matching body on the wrong host is not a match. (It also gates the expensive
    /// half — `recent(matching:)` only hydrates a flow that already passed metadata —
    /// which is structural in the scan loop, not observable from out here.)
    @Test func bodyPredicate_stillANDsWithTheCheapPredicates() async throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("loom-bodyquery-\(UUID())", isDirectory: true)
            .appendingPathComponent("flows.sqlite")
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
        let persistence = try #require(FlowPersistence(fileURL: fileURL))
        let store = FlowStore(capacity: 10, bodyBudget: 1, persistence: persistence)

        let payload = Data(#"{"trace":"T-42"}"#.utf8)
        for host in ["api.example.com", "cdn.example.com"] {
            await store.upsert(Flow(
                id: UUID(),
                request: CapturedRequest(method: "GET", url: "https://\(host)/x", headers: [], body: payload),
                startedAt: Date(timeIntervalSince1970: 1),
                outcome: .completed(CapturedResponse(statusCode: 200, headers: []), at: Date(timeIntervalSince1970: 2))
            ))
        }

        let both = await store.recent(matching: FlowQuery(bodyContains: "t-42"), limit: 10)
        #expect(both.count == 2, "precondition: both flows carry the needle")

        let narrowed = await store.recent(
            matching: FlowQuery(host: "api.example.com", bodyContains: "t-42"), limit: 10
        )
        #expect(narrowed.map(\.host) == ["api.example.com"])
    }

    /// The engine's own delegation, exercised through its public surface: two
    /// replays land in the store (one 404, one 200) and the filtered read returns
    /// only the failure.
    @Test func engineExposesTheFilteredRead() async throws {
        let upstream = QueryStubUpstream()
        let engine = ProxyEngine(forwarder: upstream, caStore: InMemoryCAStore())

        await upstream.setResult(ForwardResult(statusCode: 404, headers: [], body: Data()))
        _ = try await engine.replay(flow: flow("https://api.example.com/a", at: 1), overrides: .none)
        await upstream.setResult(ForwardResult(statusCode: 200, headers: [], body: Data()))
        _ = try await engine.replay(flow: flow("https://api.example.com/b", at: 2), overrides: .none)

        let errors = await engine.recentFlows(matching: FlowQuery(onlyErrors: true), limit: 10)
        #expect(errors.map(\.statusCode) == [404])
        #expect(await engine.recentFlows(matching: .all, limit: 10).count == 2)

        await engine.stopForTest()
    }
}

private actor QueryStubUpstream: UpstreamForwarding {
    private var result = ForwardResult(statusCode: 200, headers: [], body: Data())

    func setResult(_ result: ForwardResult) { self.result = result }
    func forward(method: String, url: URL, headers: [HeaderPair], body: Data?) async throws -> ForwardResult {
        result
    }
}
