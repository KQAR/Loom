import Foundation
import LoomSharedModels
import Testing
@testable import MCPServer

/// The human's switch that keeps captured credentials out of an agent's context.
///
/// Three properties make it worth having: every read that returns flow content goes
/// through it, the agent can tell Loom's `<redacted>` from a value on the wire, and
/// the original survives for `replay_flow` — so the debug loop still closes.
@MainActor
@Suite struct AgentRedactionToolTests {
    private func makeExecutor(_ engine: StubEngine) -> MCPToolExecutor {
        MCPToolExecutor(engine: engine, appVersion: "9.9", protocolVersion: "2025-06-18")
    }

    private func object(_ string: String) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: Data(string.utf8)) as? [String: Any])
    }

    private func secretFlow(id: UUID = UUID(), token: String = "Bearer s3cret") -> Flow {
        Flow(
            id: id,
            request: CapturedRequest(
                method: "GET", url: "https://api.example.com/me?access_token=q-s3cret&page=1",
                headers: [HeaderPair(name: "Authorization", value: token)]
            ),
            startedAt: Date(),
            outcome: .completed(
                CapturedResponse(statusCode: 200, headers: [HeaderPair(name: "Set-Cookie", value: "sid=s3cret")]),
                at: Date()
            )
        )
    }

    @Test func flowReadsAreRedactedAndMarked() async throws {
        let engine = StubEngine()
        engine.redactAgentReads = true
        let flow = secretFlow()
        engine.flows = [flow]
        let executor = makeExecutor(engine)

        let detail = try await executor.call(name: "get_flow_detail", arguments: ["id": flow.id.uuidString])
        #expect(!detail.contains("s3cret"))
        #expect(detail.contains(FlowRedaction.placeholder))
        #expect(try object(detail)["redacted"] as? Bool == true)

        let listed = try await executor.call(name: "get_recent_flows", arguments: [:])
        #expect(!listed.contains("s3cret"))
        #expect(listed.contains("\"redacted\" : true"))
    }

    @Test func offMeansVerbatim_andNoMarker() async throws {
        let engine = StubEngine()
        let flow = secretFlow()
        engine.flows = [flow]
        let detail = try await makeExecutor(engine).call(name: "get_flow_detail", arguments: ["id": flow.id.uuidString])
        #expect(detail.contains("Bearer s3cret"))
        #expect(try object(detail)["redacted"] == nil)
    }

    @Test func statusSaysSo_soARedactedValueIsNeverMistakenForTheServers() async throws {
        let engine = StubEngine()
        engine.redactAgentReads = true
        let status = try object(try await makeExecutor(engine).call(name: "get_proxy_status", arguments: [:]))
        #expect(status["redactsAgentReads"] as? Bool == true)
        let rules = try #require(status["agentRedaction"] as? [String: Any])
        #expect((rules["headers"] as? [String])?.contains("authorization") == true)
        #expect(rules["bodiesRedacted"] as? Bool == false)

        engine.redactAgentReads = false
        let off = try object(try await makeExecutor(engine).call(name: "get_proxy_status", arguments: [:]))
        #expect(off["redactsAgentReads"] as? Bool == false)
        #expect(off["agentRedaction"] == nil)
    }

    @Test func diffStillSeesARotatedToken() async throws {
        let engine = StubEngine()
        engine.redactAgentReads = true
        let base = secretFlow(token: "Bearer old-s3cret")
        let compared = secretFlow(token: "Bearer new-s3cret")
        engine.flows = [base, compared]

        let out = try await makeExecutor(engine).call(
            name: "diff_flows", arguments: ["base": base.id.uuidString, "compared": compared.id.uuidString]
        )
        #expect(!out.contains("s3cret"))
        let diff = try object(out)
        #expect(diff["identical"] as? Bool == false, "compared over the originals, then redacted")
        #expect(diff["redacted"] as? Bool == true)
    }

    @Test func replayActsOnTheOriginal_andOnlyTheResultIsRedacted() async throws {
        let engine = StubEngine()
        engine.redactAgentReads = true
        let flow = secretFlow()
        engine.flows = [flow]
        engine.replayResult = secretFlow()

        let out = try await makeExecutor(engine).call(name: "replay_flow", arguments: ["id": flow.id.uuidString])
        // The engine is asked to replay by id — it re-sends what it stored, so the
        // agent never had to hold the token for the replay to carry it.
        #expect(engine.lastReplay?.id == flow.id)
        #expect(engine.lastReplay?.overrides.setHeaders == nil)
        #expect(!out.contains("s3cret"))
    }

    @Test func heldExchangesAreRedacted() async throws {
        let engine = StubEngine()
        engine.redactAgentReads = true
        engine.hold(PendingBreakpoint(
            breakpointID: UUID(), phase: .request, method: "GET",
            url: "https://api.example.com/x", requestHeaders: [HeaderPair(name: "Cookie", value: "sid=s3cret")]
        ))
        let out = try await makeExecutor(engine).call(name: "list_pending", arguments: [:])
        #expect(!out.contains("s3cret"))
        #expect(out.contains("\"redacted\" : true"))
    }

    @Test func noToolTurnsItOff() {
        // The switch keeps credentials out of the agent's context; a tool the agent
        // could call to flip it would make it advisory.
        let names = MCPToolExecutor.tools.map(\.name)
        #expect(!names.contains { $0.contains("redact") })
    }
}
