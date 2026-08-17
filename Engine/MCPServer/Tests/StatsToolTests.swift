import Testing
import Foundation
import LoomSharedModels
@testable import MCPServer

/// `get_stats` is the tool that stops an agent from paying for arithmetic in tokens.
/// The aggregation itself is pinned in `FlowStatsTests`; what matters here is that the
/// tool aggregates *the flows the filters select*, renders the numbers an agent needs
/// to act (including the ids of the slow ones), and never quietly drops a bucket.
@MainActor
@Suite struct StatsToolTests {
    private func makeExecutor(_ engine: StubEngine) -> MCPToolExecutor {
        MCPToolExecutor(engine: engine, appVersion: "9.9", protocolVersion: "2025-06-18")
    }

    private func json(_ string: String) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: Data(string.utf8)) as? [String: Any])
    }

    private func flow(
        _ url: String, status: Int = 200, ttfbMS: Int? = nil, at seconds: TimeInterval = 1_000
    ) -> Flow {
        let startedAt = Date(timeIntervalSince1970: seconds)
        return Flow(
            id: UUID(),
            request: CapturedRequest(method: "GET", url: url, headers: []),
            startedAt: startedAt,
            outcome: .completed(CapturedResponse(statusCode: status, headers: []), at: startedAt),
            firstByteAt: ttfbMS.map { startedAt.addingTimeInterval(Double($0) / 1000) }
        )
    }

    private func failedTunnel() -> Flow {
        let startedAt = Date(timeIntervalSince1970: 1_001)
        return Flow(
            request: CapturedRequest(
                method: "CONNECT", url: "https://api.example.com:443", headers: []
            ),
            startedAt: startedAt,
            outcome: .failed(
                FlowError(
                    "Client rejected Loom's certificate",
                    code: .clientCertificateRejected
                ),
                at: startedAt,
                partialResponse: nil
            ),
            tunnelDiagnostic: Flow.TunnelDiagnostic(
                host: "api.example.com", port: 443, reason: .clientHandshakeFailed
            )
        )
    }

    @Test func groupsByHostByDefault_withCountsAndErrorRate() async throws {
        let engine = StubEngine()
        engine.flows = [
            flow("https://api.example.com/a", status: 500),
            flow("https://api.example.com/b"),
            flow("https://cdn.example.com/c"),
        ]

        let out = try await json(makeExecutor(engine).call(name: "get_stats", arguments: [:]))
        #expect(out["groupBy"] as? String == "host")
        #expect(out["flowsConsidered"] as? Int == 3)

        let buckets = try #require(out["buckets"] as? [[String: Any]])
        #expect(buckets.map { $0["key"] as? String } == ["api.example.com", "cdn.example.com"])
        #expect(buckets.first?["flows"] as? Int == 2)
        #expect(buckets.first?["errors"] as? Int == 1)
        #expect(buckets.first?["errorRate"] as? Double == 0.5)
        #expect((buckets.first?["statusClasses"] as? [String: Int])?["5xx"] == 1)
    }

    @Test func honorsTheSameFiltersAsGetRecentFlows() async throws {
        let engine = StubEngine()
        engine.flows = [
            flow("https://api.example.com/a", status: 500),
            flow("https://cdn.example.com/b", status: 500),
            flow("https://api.example.com/c"),
        ]

        let out = try await json(makeExecutor(engine).call(name: "get_stats", arguments: [
            "host": "api.example.com", "only_errors": true,
        ]))
        #expect(out["flowsConsidered"] as? Int == 1, "the filters select what gets aggregated")
        let buckets = try #require(out["buckets"] as? [[String: Any]])
        #expect(buckets.map { $0["key"] as? String } == ["api.example.com"])
    }

    @Test func connectionDiagnosticsAreSeparateFromExchangeHealth() async throws {
        let engine = StubEngine()
        engine.flows = [flow("https://api.example.com/a"), failedTunnel()]

        let out = try await json(makeExecutor(engine).call(name: "get_stats", arguments: [:]))
        #expect(out["flowsConsidered"] as? Int == 1)
        #expect(out["recordsConsidered"] as? Int == 2)
        #expect((out["total"] as? [String: Any])?["errorRate"] as? Double == 0)

        let diagnostics = try #require(out["connectionDiagnostics"] as? [String: Any])
        #expect(diagnostics["connections"] as? Int == 1)
        #expect(diagnostics["failed"] as? Int == 1)
        #expect(diagnostics["relayed"] as? Int == 0)
        #expect((diagnostics["reasons"] as? [String: Int])?["clientHandshakeFailed"] == 1)
    }

    @Test func recordTypeFilterSelectsOneRecordGrain() async throws {
        let engine = StubEngine()
        engine.flows = [flow("https://api.example.com/a"), failedTunnel()]
        let executor = makeExecutor(engine)

        let requests = try await json(executor.call(
            name: "get_stats", arguments: ["record_type": "exchange"]
        ))
        #expect(requests["flowsConsidered"] as? Int == 1)
        #expect(requests["connectionDiagnostics"] == nil)

        let connections = try await json(executor.call(
            name: "get_stats", arguments: ["record_type": "tunnel"]
        ))
        #expect(connections["flowsConsidered"] as? Int == 0)
        #expect((connections["connectionDiagnostics"] as? [String: Any])?["connections"] as? Int == 1)

        await #expect(throws: MCPError.self) {
            try await executor.call(name: "get_stats", arguments: ["record_type": "socket"])
        }
    }

    @Test func namesTheSlowestExchangesWithTheirIDs() async throws {
        let engine = StubEngine()
        let slow = flow("https://api.example.com/slow", ttfbMS: 900)
        engine.flows = [flow("https://api.example.com/fast", ttfbMS: 10), slow]

        let out = try await json(makeExecutor(engine).call(name: "get_stats", arguments: ["slowest": 1]))
        let slowest = try #require(out["slowest"] as? [[String: Any]])
        #expect(slowest.count == 1)
        #expect(slowest.first?["id"] as? String == slow.id.uuidString,
                "the id is the point — the follow-up is get_flow_detail, not another search")
        #expect(slowest.first?["ttfbMS"] as? Int == 900)

        let ttfb = try #require((out["total"] as? [String: Any])?["ttfbMS"] as? [String: Any])
        #expect(ttfb["max"] as? Int == 900)
        #expect(ttfb["samples"] as? Int == 2)
    }

    @Test func aCappedBucketListSaysHowManyItDropped() async throws {
        let engine = StubEngine()
        engine.flows = (0 ..< 5).map { flow("https://host\($0).test/x") }

        let out = try await json(makeExecutor(engine).call(name: "get_stats", arguments: ["limit": 2]))
        #expect((out["buckets"] as? [[String: Any]])?.count == 2)
        #expect(out["bucketsOmitted"] as? Int == 3, "a truncated ranking must never look complete")
    }

    @Test func groupBy_acceptsEveryGroupingAndRejectsNonsense() async throws {
        let engine = StubEngine()
        engine.flows = [flow("https://api.example.com/v1/orders/42")]
        let executor = makeExecutor(engine)

        for grouping in FlowGrouping.allCases {
            let out = try await json(executor.call(name: "get_stats", arguments: ["group_by": grouping.rawValue]))
            #expect(out["groupBy"] as? String == grouping.rawValue)
        }

        let endpoint = try await json(executor.call(name: "get_stats", arguments: ["group_by": "endpoint"]))
        #expect((endpoint["buckets"] as? [[String: Any]])?.first?["key"] as? String == "GET /v1/orders/{id}")

        await #expect(throws: MCPError.self) {
            try await executor.call(name: "get_stats", arguments: ["group_by": "vibes"])
        }
    }

    @Test func anEmptyCaptureIsZeroes_notAnError() async throws {
        let out = try await json(makeExecutor(StubEngine()).call(name: "get_stats", arguments: [:]))
        #expect(out["flowsConsidered"] as? Int == 0)
        #expect((out["buckets"] as? [[String: Any]])?.isEmpty == true)
        #expect(out["from"] == nil, "no flows, no window")
    }

    @Test func readingStatsIsNotAWriteAction() async throws {
        let engine = StubEngine()
        _ = try await makeExecutor(engine).call(name: "get_stats", arguments: [:])
        #expect(engine.recordedAudits.isEmpty)
        #expect(!MCPToolExecutor.writeTools.contains("get_stats"))
    }
}
