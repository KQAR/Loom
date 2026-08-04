import Testing
import Foundation
import LoomSharedModels
@testable import MCPServer

/// The MCP surface for reverse-proxy endpoints: what the agent can ask for, what it
/// gets told, and what lands in the audit trail.
@MainActor
@Suite struct ReverseProxyToolTests {
    private func makeExecutor(_ engine: StubEngine) -> MCPToolExecutor {
        MCPToolExecutor(engine: engine, appVersion: "9.9", protocolVersion: "2025-06-18")
    }

    private func json(_ string: String) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: Data(string.utf8)) as? [String: Any])
    }

    // MARK: create

    @Test func creatingAnEndpointReportsWhereToPointTheClient() async throws {
        let engine = StubEngine()
        let payload = try await json(makeExecutor(engine).call(
            name: "create_reverse_proxy",
            arguments: ["upstream": "https://api.example.com", "label": "checkout"]
        ))
        #expect(payload["upstream"] as? String == "https://api.example.com")
        #expect(payload["listening"] as? Bool == true)
        // The address is the deliverable — without it the agent has nothing to put in
        // the dev server's config.
        #expect((payload["localURL"] as? String)?.hasPrefix("http://127.0.0.1:") == true)
        #expect(payload["label"] as? String == "checkout")
        // And the instruction: reporting a created endpoint without saying the client
        // must be re-pointed is how an agent concludes "capture is fixed" while the
        // dev server still bypasses Loom entirely.
        let next = try #require(payload["nextStep"] as? String)
        #expect(next.contains("no CA trust"))
    }

    @Test func aBareHostIsRejectedInBandWithTheReason() async throws {
        let engine = StubEngine()
        let error = await #expect(throws: MCPToolFailure.self) {
            _ = try await self.makeExecutor(engine).call(
                name: "create_reverse_proxy", arguments: ["upstream": "api.example.com"])
        }
        // A domain failure, not a protocol one: the agent should see it in the result
        // and fix the argument rather than have the turn fault.
        #expect(try #require(error).message.contains("http:// or https://"))
        #expect(engine.storedReverseProxies.isEmpty, "a rejected create must not leave an endpoint behind")
    }

    @Test func aMissingUpstreamIsAProtocolError() async {
        let engine = StubEngine()
        await #expect(throws: MCPError.self) {
            _ = try await self.makeExecutor(engine).call(name: "create_reverse_proxy", arguments: [:])
        }
    }

    @Test func anExplicitPortIsHonored() async throws {
        let engine = StubEngine()
        let payload = try await json(makeExecutor(engine).call(
            name: "create_reverse_proxy",
            arguments: ["upstream": "https://api.example.com", "port": 9345]
        ))
        #expect(payload["localURL"] as? String == "http://127.0.0.1:9345")
    }

    // MARK: list + status

    @Test func listingReportsEveryEndpoint() async throws {
        let engine = StubEngine()
        let executor = makeExecutor(engine)
        _ = try await executor.call(name: "create_reverse_proxy", arguments: ["upstream": "https://a.example.com"])
        _ = try await executor.call(name: "create_reverse_proxy", arguments: ["upstream": "https://b.example.com"])

        let payload = try await json(executor.call(name: "list_reverse_proxies", arguments: [:]))
        #expect(payload["count"] as? Int == 2)
        let listed = try #require(payload["reverseProxies"] as? [[String: Any]])
        #expect(listed.compactMap { $0["upstream"] as? String } == ["https://a.example.com", "https://b.example.com"])
    }

    /// An endpoint that isn't listening is the "why is nothing captured" case — a
    /// client pointed at it gets connection refused, which reads like Loom is down —
    /// so the reason has to travel with it.
    @Test func anEndpointThatIsNotListeningCarriesItsError() {
        let rendered = MCPToolExecutor.renderReverseProxy(ReverseProxyStatus(
            endpoint: ReverseProxyEndpoint(requestedPort: 9200, upstream: "https://api.example.com"),
            error: "could not listen on port 9200: address already in use"
        ))
        #expect(rendered["listening"] as? Bool == false)
        #expect(rendered["localURL"] == nil, "there is nothing to point a client at")
        #expect((rendered["error"] as? String)?.contains("already in use") == true)
    }

    @Test func proxyStatusSurfacesEndpointsOnceTheyExist() async throws {
        let engine = StubEngine()
        let executor = makeExecutor(engine)

        // Absent while there are none, so its presence is itself information.
        let before = try await json(executor.call(name: "get_proxy_status", arguments: [:]))
        #expect(before["reverseProxies"] == nil)

        _ = try await executor.call(name: "create_reverse_proxy", arguments: ["upstream": "https://api.example.com"])
        let after = try await json(executor.call(name: "get_proxy_status", arguments: [:]))
        let listed = try #require(after["reverseProxies"] as? [[String: Any]])
        #expect(listed.first?["upstream"] as? String == "https://api.example.com")
    }

    // MARK: delete

    @Test func deletingClosesTheEndpointAndSaysWhatThatMeans() async throws {
        let engine = StubEngine()
        let executor = makeExecutor(engine)
        let created = try await json(executor.call(
            name: "create_reverse_proxy", arguments: ["upstream": "https://api.example.com"]))
        let id = try #require(created["id"] as? String)

        let payload = try await json(executor.call(name: "delete_reverse_proxy", arguments: ["id": id]))
        #expect(payload["deleted"] as? String == id)
        // A dev server may still name that port; say so rather than reporting a bare success.
        #expect((payload["detail"] as? String)?.contains("connection refused") == true)
        #expect(engine.storedReverseProxies.isEmpty)
    }

    @Test func deletingAnUnknownEndpointFailsInBand() async {
        let engine = StubEngine()
        await #expect(throws: MCPToolFailure.self) {
            _ = try await self.makeExecutor(engine).call(
                name: "delete_reverse_proxy", arguments: ["id": UUID().uuidString])
        }
    }

    @Test func aMalformedIDIsAProtocolError() async {
        let engine = StubEngine()
        await #expect(throws: MCPError.self) {
            _ = try await self.makeExecutor(engine).call(
                name: "delete_reverse_proxy", arguments: ["id": "not-a-uuid"])
        }
    }

    // MARK: Supervision

    /// Opening a listening port on the human's machine is a write action, so it is
    /// audited — that is the guardrail, given there is no approval prompt.
    @Test func creatingAndDeletingAreAudited() async throws {
        let engine = StubEngine()
        let executor = makeExecutor(engine)
        let created = try await json(executor.call(
            name: "create_reverse_proxy", arguments: ["upstream": "https://api.example.com"]))
        _ = try await executor.call(
            name: "delete_reverse_proxy", arguments: ["id": try #require(created["id"] as? String)])

        let tools = engine.recordedAudits.map(\.tool)
        #expect(tools.contains("create_reverse_proxy"))
        #expect(tools.contains("delete_reverse_proxy"))
    }

    @Test func listingIsNotAWriteAction() async throws {
        let engine = StubEngine()
        _ = try await makeExecutor(engine).call(name: "list_reverse_proxies", arguments: [:])
        #expect(engine.recordedAudits.isEmpty)
    }

    /// The write tools have to *say* they are writes: the flag drives auditing, the
    /// prose is what the agent reads, and neither can be derived from the other.
    @Test func theWriteToolsDeclareThemselves() throws {
        for name in ["create_reverse_proxy", "delete_reverse_proxy"] {
            let tool = try #require(MCPToolExecutor.toolsByName[name])
            #expect(tool.isWrite)
            #expect(tool.description.contains("This is a write action."), "\(name) doesn't say so")
        }
        #expect(MCPToolExecutor.toolsByName["list_reverse_proxies"]?.isWrite == false)
    }
}
