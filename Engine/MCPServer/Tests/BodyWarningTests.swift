import Testing
import Foundation
import LoomSharedModels
@testable import MCPServer

/// A body meant to be JSON that isn't must be *sent* (mocking a malformed payload is
/// a real debugging move) and must not be *silent* — the write reports success, so
/// without a warning the client's parse error reads as the client's own bug.
@MainActor
@Suite struct BodyWarningTests {
    private func makeExecutor(_ engine: StubEngine) -> MCPToolExecutor {
        MCPToolExecutor(engine: engine, appVersion: "9.9", protocolVersion: "2025-06-18")
    }

    private func object(_ json: String) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
    }

    private func warnings(_ json: String) throws -> [String] {
        try object(json)["warnings"] as? [String] ?? []
    }

    /// `actions` is `sending` because `MCPToolExecutor.call` is nonisolated and this
    /// suite is `@MainActor`: a plain `[String: Any]` parameter would belong to the
    /// caller's (main-actor) region, and handing it to a nonisolated async function is
    /// exactly the escape strict concurrency flags. Every call site passes a fresh
    /// literal, so marking it `sending` states the truth — the dictionary is
    /// disconnected — rather than suppressing the diagnostic.
    private func setRule(_ executor: MCPToolExecutor, actions: sending [String: Any]) async throws -> String {
        try await executor.call(name: "set_rule", arguments: [
            "name": "mock", "match": ["url_pattern": "https://api.example.com/*"], "actions": actions,
        ])
    }

    // MARK: The case this exists for

    @Test func mockBodyDeclaringJSON_thatDoesNotParse_isWarnedAbout() async throws {
        let engine = StubEngine()
        let result = try await setRule(makeExecutor(engine), actions: [
            "mock_response": ["body": "{\"a\":}", "content_type": "application/json"],
        ])
        let warning = try #require(try warnings(result).first)
        #expect(warning.contains("actions.mockResponse.body"))
        #expect(warning.contains("Content-Type declares JSON"))
        // The parse position is the part that makes the typo findable.
        #expect(warning.contains("column 5"))
        // The rule is still written — the warning is a warning, not a refusal.
        #expect(engine.addedRules.count == 1)
    }

    @Test func aMalformedBodyIsStillStoredVerbatim() async throws {
        let engine = StubEngine()
        _ = try await setRule(makeExecutor(engine), actions: [
            "mock_response": ["body": "{\"a\":}", "content_type": "application/json"],
        ])
        guard case let .mock(mock) = try #require(engine.addedRules.first).actions.route else {
            Issue.record("expected a mock route"); return
        }
        #expect(mock.bodyText == "{\"a\":}")
    }

    @Test func contentTypeInTheHeadersDict_countsAsDeclaringJSON() async throws {
        let result = try await setRule(makeExecutor(StubEngine()), actions: [
            "mock_response": ["body": "not json", "headers": ["Content-Type": "application/json; charset=utf-8"]],
        ])
        #expect(try warnings(result).count == 1)
    }

    /// No declared type at all, but nobody types `{"a":}` and means it.
    @Test func aBodyThatOnlyLooksLikeJSON_isWarnedAbout() async throws {
        let result = try await setRule(makeExecutor(StubEngine()), actions: [
            "mock_response": ["body": "{\"a\":}"],
        ])
        let warning = try #require(try warnings(result).first)
        #expect(warning.contains("starts like a JSON document"))
    }

    // MARK: What must stay quiet

    @Test func validJSON_warnsAboutNothing() async throws {
        let result = try await setRule(makeExecutor(StubEngine()), actions: [
            "mock_response": ["body": "{\"a\":1}", "content_type": "application/json"],
        ])
        #expect(try object(result)["warnings"] == nil)
    }

    @Test func aBodyNotTryingToBeJSON_warnsAboutNothing() async throws {
        let result = try await setRule(makeExecutor(StubEngine()), actions: [
            "mock_response": ["body": "<html>hi</html>", "content_type": "text/html"],
        ])
        #expect(try warnings(result).isEmpty)
    }

    /// RFC 8259 makes a bare scalar a legal document; warning about `42` would be
    /// noise, and noise is what teaches an agent to ignore the field.
    @Test func aJSONScalarBody_warnsAboutNothing() async throws {
        let result = try await setRule(makeExecutor(StubEngine()), actions: [
            "mock_response": ["body": "42", "content_type": "application/json"],
        ])
        #expect(try warnings(result).isEmpty)
    }

    @Test func anEmptyBody_warnsAboutNothing() async throws {
        let result = try await setRule(makeExecutor(StubEngine()), actions: [
            "mock_response": ["body": "", "content_type": "application/json"],
        ])
        #expect(try warnings(result).isEmpty)
    }

    @Test func aBinaryBase64Body_isNotTreatedAsJSON() async throws {
        let result = try await setRule(makeExecutor(StubEngine()), actions: [
            "mock_response": ["body_base64": Data("{\"a\":}".utf8).base64EncodedString(), "content_type": "application/json"],
        ])
        #expect(try warnings(result).isEmpty)
    }

    // MARK: The other bodies a rule can carry

    @Test func rewriteBodies_areNamedByTheirOwnPath() async throws {
        let result = try await setRule(makeExecutor(StubEngine()), actions: [
            "rewrite_request": ["body": "{\"a\":}"],
            "rewrite_response": ["body": "[1,", "set_headers": ["content-type": "application/json"]],
        ])
        let reported = try warnings(result)
        #expect(reported.count == 2)
        #expect(reported.contains { $0.contains("actions.rewriteRequest.body") })
        #expect(reported.contains { $0.contains("actions.rewriteResponse.body") })
    }

    // MARK: The two tools that send a body directly

    @Test func replayWithAMalformedJSONBody_stillReplaysAndWarns() async throws {
        let engine = StubEngine()
        let result = try await makeExecutor(engine).call(name: "replay_flow", arguments: [
            "id": UUID().uuidString,
            "body": "{\"a\":}",
            "set_headers": ["Content-Type": "application/json"],
        ])
        #expect(try warnings(result).first?.contains("body is not valid JSON") == true)
        #expect(engine.lastReplay != nil)
    }

    @Test func batchReplayCarriesTheSameWarning() async throws {
        let engine = StubEngine()
        let result = try await makeExecutor(engine).call(name: "replay_flow", arguments: [
            "id": UUID().uuidString, "count": 3, "body": "{\"a\":}",
        ])
        #expect(try warnings(result).count == 1)
        #expect(try object(result)["requested"] as? Int == 3)
    }

    @Test func resumeWithAMalformedJSONBody_stillResumesAndWarns() async throws {
        let engine = StubEngine()
        let held = PendingBreakpoint(
            breakpointID: UUID(), phase: .request, method: "POST",
            url: "https://api.example.com/v1/pay", requestHeaders: []
        )
        engine.hold(held)
        let result = try await makeExecutor(engine).call(name: "resume", arguments: [
            "pending_id": held.id.uuidString, "body": "{\"a\":}",
        ])
        #expect(try warnings(result).count == 1)
        #expect(try object(result)["resumed"] as? String == held.id.uuidString)
    }

    /// An abort discards the edit, so a warning about the body it wasn't going to
    /// send would be misleading.
    @Test func abortingWarnsAboutNothing() async throws {
        let engine = StubEngine()
        let held = PendingBreakpoint(
            breakpointID: UUID(), phase: .request, method: "POST",
            url: "https://api.example.com/v1/pay", requestHeaders: []
        )
        engine.hold(held)
        let result = try await makeExecutor(engine).call(name: "resume", arguments: [
            "pending_id": held.id.uuidString, "body": "{\"a\":}", "abort": true,
        ])
        #expect(try warnings(result).isEmpty)
    }
}
