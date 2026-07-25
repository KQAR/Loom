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
    }
}

private actor QueryStubUpstream: UpstreamForwarding {
    private var result = ForwardResult(statusCode: 200, headers: [], body: Data())

    func setResult(_ result: ForwardResult) { self.result = result }
    func forward(method: String, url: URL, headers: [HeaderPair], body: Data?) async throws -> ForwardResult {
        result
    }
}
