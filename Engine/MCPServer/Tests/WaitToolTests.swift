import Testing
import Foundation
import LoomSharedModels
@testable import MCPServer

/// `wait_for_flow` / `wait_for_pending` exist so an agent stops burning turns on a
/// poll loop. What has to hold for that to be an improvement rather than a trap:
///
/// - a match that is **already** there comes back immediately (the tool is a query
///   over the retained capture first, a wait second),
/// - a match that arrives **during** the wait comes back too, with no gap between
///   "looked in the store" and "started listening",
/// - a timeout is a **normal result** (`timedOut: true`), not an error, and it never
///   consumes anything: the flow stays in the store for the next call,
/// - `until` decides how much of the exchange counts, so an agent that asked for a
///   finished exchange isn't handed a request with no response yet.
@MainActor
@Suite struct WaitToolTests {
    private func makeExecutor(_ engine: StubEngine) -> MCPToolExecutor {
        MCPToolExecutor(engine: engine, appVersion: "9.9", protocolVersion: "2025-06-18")
    }

    private func json(_ string: String) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: Data(string.utf8)) as? [String: Any])
    }

    private func flow(
        url: String = "https://api.example.com/v1/orders",
        method: String = "POST",
        status: Int? = 200,
        startedAt: Date = Date()
    ) -> Flow {
        Flow(
            id: UUID(),
            request: CapturedRequest(method: method, url: url, headers: []),
            startedAt: startedAt,
            outcome: status.map { .completed(CapturedResponse(statusCode: $0, headers: []), at: Date()) } ?? .pending
        )
    }

    private func pending(breakpointID: UUID = UUID(), url: String = "https://api.example.com/v1/orders") -> PendingBreakpoint {
        PendingBreakpoint(
            breakpointID: breakpointID, phase: .request, method: "POST", url: url, requestHeaders: []
        )
    }

    // MARK: - wait_for_flow

    @Test func returnsAMatchAlreadyInTheStore_withoutWaiting() async throws {
        let engine = StubEngine()
        engine.flows = [flow()]
        let executor = makeExecutor(engine)

        let started = Date()
        let result = try await json(executor.call(name: "wait_for_flow", arguments: [
            "host": "api.example.com",
            // An explicit window, because the default is "from now on" — see below.
            "since_seconds": 60,
            "max_seconds": 10,
        ]))

        #expect(Date().timeIntervalSince(started) < 1, "a stored match must not wait at all")
        #expect(result["timedOut"] as? Bool == false)
        #expect((result["matched"] as? [[String: Any]])?.count == 1)
    }

    @Test func withoutAnExplicitWindow_ancientTrafficDoesNotCount() async throws {
        let engine = StubEngine()
        engine.flows = [flow(startedAt: Date().addingTimeInterval(-3600))]
        let executor = makeExecutor(engine)

        let result = try await json(executor.call(name: "wait_for_flow", arguments: ["max_seconds": 0.2]))
        #expect(result["timedOut"] as? Bool == true, "an hour-old flow is not what \"wait for it\" means")
        #expect((result["matched"] as? [[String: Any]])?.isEmpty == true)
    }

    /// The sequence an agent actually runs is *trigger the action, then call the
    /// tool* — so a request captured a moment **before** the call must still count.
    /// A strict "from now on" window would time out on traffic already in the store,
    /// which is the exact failure this tool exists to remove.
    @Test func trafficCapturedJustBeforeTheCall_stillCounts() async throws {
        let engine = StubEngine()
        engine.flows = [flow(startedAt: Date().addingTimeInterval(-2))]
        let executor = makeExecutor(engine)

        let result = try await json(executor.call(name: "wait_for_flow", arguments: ["max_seconds": 0.2]))
        #expect(result["timedOut"] as? Bool == false)
        #expect((result["matched"] as? [[String: Any]])?.count == 1)
    }

    @Test func returnsAFlowThatArrivesDuringTheWait() async throws {
        let engine = StubEngine()
        let executor = makeExecutor(engine)
        let arriving = flow(url: "https://api.example.com/v1/checkout")

        async let response = executor.call(name: "wait_for_flow", arguments: [
            "url_contains": "checkout", "max_seconds": 5,
        ])
        // Let the wait subscribe, then push. (Even if this lands first, the store
        // pre-check would catch it — that redundancy is the point.)
        try await Task.sleep(nanoseconds: 100_000_000)
        engine.emit(arriving)

        let result = try await json(response)
        #expect(result["timedOut"] as? Bool == false)
        let matched = try #require(result["matched"] as? [[String: Any]])
        #expect(matched.first?["id"] as? String == arriving.id.uuidString)
    }

    @Test func timingOutIsANormalResult_andReportsWhereToResumeFrom() async throws {
        let engine = StubEngine()
        let executor = makeExecutor(engine)

        let result = try await json(executor.call(name: "wait_for_flow", arguments: ["max_seconds": 0.2]))
        #expect(result["timedOut"] as? Bool == true)
        #expect((result["matched"] as? [[String: Any]])?.isEmpty == true)
        #expect((result["waitedMS"] as? Int) ?? -1 >= 0)
        // The cursor for a gapless retry — the whole reason a timeout is harmless.
        let windowFrom = try #require(result["windowFrom"] as? String)
        #expect(ISO8601DateFormatter().date(from: windowFrom) != nil)
    }

    @Test func untilCompleted_ignoresARequestWithNoResponseYet() async throws {
        let engine = StubEngine()
        let executor = makeExecutor(engine)
        let inFlight = flow(status: nil)

        async let response = executor.call(name: "wait_for_flow", arguments: ["max_seconds": 0.4])
        try await Task.sleep(nanoseconds: 50_000_000)
        engine.emit(inFlight)

        let result = try await json(response)
        #expect(result["timedOut"] as? Bool == true, "the default `completed` must not settle for a pending flow")
    }

    @Test func untilRequest_returnsTheSightingImmediately() async throws {
        let engine = StubEngine()
        let executor = makeExecutor(engine)
        let inFlight = flow(status: nil)

        async let response = executor.call(name: "wait_for_flow", arguments: [
            "until": "request", "max_seconds": 5,
        ])
        try await Task.sleep(nanoseconds: 50_000_000)
        engine.emit(inFlight)

        let result = try await json(response)
        #expect(result["timedOut"] as? Bool == false)
        #expect((result["matched"] as? [[String: Any]])?.count == 1)
    }

    @Test func theFilterVocabularyIsTheOneGetRecentFlowsUses() async throws {
        let engine = StubEngine()
        let executor = makeExecutor(engine)
        let wanted = Flow(
            id: UUID(),
            request: CapturedRequest(
                method: "POST", url: "https://api.example.com/graphql", headers: [],
                body: Data(#"{"operationName":"Checkout"}"#.utf8)
            ),
            startedAt: Date(),
            outcome: .completed(CapturedResponse(statusCode: 500, headers: []), at: Date())
        )

        async let response = executor.call(name: "wait_for_flow", arguments: [
            "body_contains": "checkout", "only_errors": true, "max_seconds": 5,
        ])
        try await Task.sleep(nanoseconds: 50_000_000)
        engine.emit(flow(url: "https://api.example.com/graphql", status: 200)) // right host, not an error
        engine.emit(wanted)

        let result = try await json(response)
        let matched = try #require(result["matched"] as? [[String: Any]])
        #expect(matched.map { $0["id"] as? String } == [wanted.id.uuidString])
    }

    @Test func waitsForSeveralWhenAskedTo_andKeepsPartialsOnTimeout() async throws {
        let engine = StubEngine()
        let executor = makeExecutor(engine)

        async let response = executor.call(name: "wait_for_flow", arguments: [
            "host": "api.example.com", "limit": 3, "max_seconds": 0.5,
        ])
        try await Task.sleep(nanoseconds: 50_000_000)
        engine.emit(flow())
        engine.emit(flow())

        let result = try await json(response)
        #expect(result["timedOut"] as? Bool == true, "it never saw the third")
        #expect((result["matched"] as? [[String: Any]])?.count == 2,
                "…but reports the two it did see rather than pretending it saw none")
    }

    @Test func oneFlowEmittedRepeatedly_countsOnce() async throws {
        let engine = StubEngine()
        let executor = makeExecutor(engine)
        // A real exchange is broadcast on request, on each streaming update and on
        // completion. `limit: 2` must mean two exchanges, not two emissions.
        let subject = flow(status: nil)

        async let response = executor.call(name: "wait_for_flow", arguments: [
            "until": "request", "limit": 2, "max_seconds": 0.4,
        ])
        try await Task.sleep(nanoseconds: 50_000_000)
        engine.emit(subject)
        engine.emit(subject)

        let result = try await json(response)
        #expect((result["matched"] as? [[String: Any]])?.count == 1)
        #expect(result["timedOut"] as? Bool == true)
    }

    // MARK: - Argument validation

    @Test func maxSeconds_isClampedToTheTransportLimit_notRejected() throws {
        #expect(try MCPToolExecutor.waitSeconds(from: [:]) == MCPToolExecutor.defaultWaitSeconds)
        #expect(try MCPToolExecutor.waitSeconds(from: ["max_seconds": 5]) == 5)
        #expect(try MCPToolExecutor.waitSeconds(from: ["max_seconds": 6000]) == MCPToolExecutor.maxWaitSeconds,
                "a client asking for longer than the MCP transport tolerates gets the longest safe wait")
        #expect(throws: MCPError.self) { try MCPToolExecutor.waitSeconds(from: ["max_seconds": 0]) }
        #expect(throws: MCPError.self) { try MCPToolExecutor.waitSeconds(from: ["max_seconds": "soon"]) }
    }

    @Test func until_rejectsAnUnknownValue() throws {
        #expect(try MCPToolExecutor.waitUntil(from: [:]) == .completed)
        #expect(try MCPToolExecutor.waitUntil(from: ["until": "RESPONSE"]) == .response)
        #expect(throws: MCPError.self) { try MCPToolExecutor.waitUntil(from: ["until": "eventually"]) }
    }

    @Test func waitForPending_rejectsAMalformedBreakpointID() async {
        let executor = makeExecutor(StubEngine())
        await #expect(throws: MCPError.self) {
            try await executor.call(name: "wait_for_pending", arguments: ["breakpoint_id": "not-a-uuid"])
        }
    }

    // MARK: - wait_for_pending

    @Test func returnsAnExchangeAlreadyHeld() async throws {
        let engine = StubEngine()
        let held = pending()
        engine.pending = [held]
        let executor = makeExecutor(engine)

        let result = try await json(executor.call(name: "wait_for_pending", arguments: ["max_seconds": 10]))
        #expect(result["timedOut"] as? Bool == false)
        let items = try #require(result["pending"] as? [[String: Any]])
        #expect(items.first?["id"] as? String == held.id.uuidString)
    }

    @Test func returnsAnExchangeHeldDuringTheWait() async throws {
        let engine = StubEngine()
        let executor = makeExecutor(engine)
        let held = pending()

        async let response = executor.call(name: "wait_for_pending", arguments: ["max_seconds": 5])
        try await Task.sleep(nanoseconds: 100_000_000)
        engine.hold(held)

        let result = try await json(response)
        #expect(result["timedOut"] as? Bool == false)
        #expect((result["pending"] as? [[String: Any]])?.first?["id"] as? String == held.id.uuidString)
    }

    @Test func breakpointIDNarrowsWhichHoldEndsTheWait() async throws {
        let engine = StubEngine()
        let executor = makeExecutor(engine)
        let wanted = UUID()
        let mine = pending(breakpointID: wanted)

        async let response = executor.call(name: "wait_for_pending", arguments: [
            "breakpoint_id": wanted.uuidString, "max_seconds": 5,
        ])
        try await Task.sleep(nanoseconds: 100_000_000)
        engine.hold(pending()) // another breakpoint's hold
        engine.hold(mine)

        let result = try await json(response)
        let items = try #require(result["pending"] as? [[String: Any]])
        #expect(items.map { $0["id"] as? String } == [mine.id.uuidString])
    }

    @Test func waitForPending_timesOutWithNothingHeld() async throws {
        let executor = makeExecutor(StubEngine())
        let result = try await json(executor.call(name: "wait_for_pending", arguments: ["max_seconds": 0.2]))
        #expect(result["timedOut"] as? Bool == true)
        #expect((result["pending"] as? [[String: Any]])?.isEmpty == true)
    }

    /// Neither wait tool touches traffic, so neither may land in the audit trail —
    /// the trail is the human's record of what the agent *did*, and padding it with
    /// reads is how it stops being read.
    @Test func waitingIsNotAWriteAction() async throws {
        let engine = StubEngine()
        let executor = makeExecutor(engine)
        _ = try await executor.call(name: "wait_for_flow", arguments: ["max_seconds": 0.1])
        _ = try await executor.call(name: "wait_for_pending", arguments: ["max_seconds": 0.1])
        #expect(engine.recordedAudits.isEmpty)
        #expect(!MCPToolExecutor.writeTools.contains("wait_for_flow"))
        #expect(!MCPToolExecutor.writeTools.contains("wait_for_pending"))
    }
}
