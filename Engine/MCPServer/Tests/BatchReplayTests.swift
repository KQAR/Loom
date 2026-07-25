import Testing
import Foundation
import LoomSharedModels
@testable import MCPServer

/// `replay_flow` with `count` exists for the questions one replay can't answer: is
/// this failure intermittent, and does it survive a few requests in parallel? That
/// only works if a failing attempt is *reported* rather than ending the batch, and if
/// the summary is honest about how many of each outcome there were.
@MainActor
@Suite struct BatchReplayTests {
    private func makeExecutor(_ engine: StubEngine) -> MCPToolExecutor {
        MCPToolExecutor(engine: engine, appVersion: "9.9", protocolVersion: "2025-06-18")
    }

    private func json(_ string: String) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: Data(string.utf8)) as? [String: Any])
    }

    private let sourceID = UUID()

    @Test func oneReplayKeepsTheSingleFlowShape() async throws {
        let engine = StubEngine()
        let executor = makeExecutor(engine)

        let implicit = try await json(executor.call(name: "replay_flow", arguments: ["id": sourceID.uuidString]))
        #expect(implicit["id"] != nil, "the default is still one flow, not a batch summary")
        #expect(implicit["requested"] == nil)

        // An explicit count of 1 is the same thing said out loud.
        let explicit = try await json(executor.call(
            name: "replay_flow", arguments: ["id": sourceID.uuidString, "count": 1]
        ))
        #expect(explicit["id"] != nil)
        #expect(engine.replayCallCount == 2)
    }

    @Test func sendsItTheRequestedNumberOfTimes_andSummarizesTheOutcomes() async throws {
        let engine = StubEngine()
        engine.replayScript = [.status(200), .status(200), .status(500), .status(200), .status(429)]
        let executor = makeExecutor(engine)

        let out = try await json(executor.call(
            name: "replay_flow", arguments: ["id": sourceID.uuidString, "count": 5]
        ))
        #expect(engine.replayCallCount == 5)
        #expect(out["requested"] as? Int == 5)
        #expect(out["succeeded"] as? Int == 5, "a 500 is a successful replay of a failing request")
        #expect(out["failed"] as? Int == 0)
        let classes = try #require(out["statusClasses"] as? [String: Int])
        #expect(classes == ["2xx": 3, "5xx": 1, "4xx": 1])
        #expect((out["replays"] as? [[String: Any]])?.count == 5)
        #expect(out["ttfbMS"] != nil, "latency across the batch is the other half of the answer")
    }

    @Test func aFailedAttemptIsReported_notThrown() async throws {
        let engine = StubEngine()
        engine.replayScript = [
            .status(200), .failure("connection refused"), .status(200), .failure("connection refused"),
        ]
        let executor = makeExecutor(engine)

        let out = try await json(executor.call(
            name: "replay_flow", arguments: ["id": sourceID.uuidString, "count": 4]
        ))
        #expect(out["succeeded"] as? Int == 2)
        #expect(out["failed"] as? Int == 2, "\"2 of 4 failed\" is the answer, so it can't be an exception")

        // Identical messages collapse with a count: 20 copies of one fact is one fact.
        let errors = try #require(out["errors"] as? [[String: Any]])
        #expect(errors.count == 1)
        #expect(errors.first?["count"] as? Int == 2)
        #expect((errors.first?["message"] as? String)?.contains("connection refused") == true)
    }

    @Test func concurrencyIsHonored_andBoundedByIt() async throws {
        let engine = StubEngine()
        engine.replayScript = Array(repeating: .slow(seconds: 0.15), count: 6)
        let executor = makeExecutor(engine)

        _ = try await executor.call(name: "replay_flow", arguments: [
            "id": sourceID.uuidString, "count": 6, "concurrency": 3,
        ])
        #expect(engine.replayCallCount == 6)
        #expect(engine.peakConcurrentReplays > 1, "concurrency 3 must actually overlap attempts")
        #expect(engine.peakConcurrentReplays <= 3, "…and must not exceed what was asked for")
    }

    @Test func sequentialByDefault() async throws {
        let engine = StubEngine()
        engine.replayScript = Array(repeating: .slow(seconds: 0.05), count: 4)
        _ = try await makeExecutor(engine).call(name: "replay_flow", arguments: [
            "id": sourceID.uuidString, "count": 4,
        ])
        #expect(engine.peakConcurrentReplays == 1, "no concurrency argument means one at a time")
    }

    @Test func anOversizedBatchIsRejected_notSilentlyClamped() async throws {
        let engine = StubEngine()
        let executor = makeExecutor(engine)

        await #expect(throws: MCPError.self) {
            try await executor.call(name: "replay_flow", arguments: [
                "id": sourceID.uuidString, "count": MCPToolExecutor.maxReplayCount + 1,
            ])
        }
        await #expect(throws: MCPError.self) {
            try await executor.call(name: "replay_flow", arguments: [
                "id": sourceID.uuidString, "count": 5,
                "concurrency": MCPToolExecutor.maxReplayConcurrency + 1,
            ])
        }
        await #expect(throws: MCPError.self) {
            try await executor.call(name: "replay_flow", arguments: ["id": sourceID.uuidString, "count": 0])
        }
        #expect(engine.replayCallCount == 0, "a rejected batch must not have sent anything")
    }

    @Test func boundedInt_defaultsAndCeilings() throws {
        #expect(try MCPToolExecutor.boundedInt(nil, field: "count", default: 1, max: 50) == 1)
        #expect(try MCPToolExecutor.boundedInt(7, field: "count", default: 1, max: 50) == 7)
        #expect(throws: MCPError.self) {
            try MCPToolExecutor.boundedInt("many", field: "count", default: 1, max: 50)
        }
    }

    /// The whole batch is one audited write action, carrying the count in its
    /// arguments — the supervising human sees "50 replays", not nothing.
    @Test func theBatchIsAuditedOnce_withItsSize() async throws {
        let engine = StubEngine()
        engine.replayScript = Array(repeating: .status(200), count: 3)
        _ = try await makeExecutor(engine).call(name: "replay_flow", arguments: [
            "id": sourceID.uuidString, "count": 3,
        ])
        #expect(engine.recordedAudits.count == 1)
        let entry = try #require(engine.recordedAudits.first)
        #expect(entry.tool == "replay_flow")
        #expect(entry.succeeded)
        #expect(entry.arguments.contains("\"count\":3"))
    }
}
