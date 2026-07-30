import Testing
import Foundation
import LoomSharedModels
@testable import MCPServer

/// Loom serves two MCP revisions on one endpoint: `2026-07-28` ("modern" — per-request
/// `_meta`, no handshake, headers mirrored from the body) and `2025-06-18` ("legacy" —
/// `initialize`). These tests exist because the failure mode is silent in both
/// directions:
///
/// - Serve a modern request under legacy rules and it *appears* to work — `tools/list`
///   and `tools/call` have the same names in both eras — so a dual-era client latches
///   "this server is modern", never falls back, and then breaks on the first thing that
///   actually differs. Before this, Loom answered a modern probe with `200 OK`.
/// - Serve a legacy request under modern rules and every client that hasn't rolled over
///   yet, Claude Code and Cursor included, simply stops connecting. A legacy client has
///   no way to fall *forward*.
///
/// So each test pins which era answered, not merely that something answered: the modern
/// marker is `resultType`, and the legacy marker is its absence.
@MainActor
@Suite struct DualEraTests {
    // MARK: Harness

    private func startServer() async throws -> (server: MCPServer, url: URL, engine: StubEngine) {
        let engine = StubEngine()
        let server = MCPServer(engine: engine, appVersion: "9.9", token: "test-token")
        // `announce: false` — a test must not overwrite the real app's handshake file.
        let port = try await server.start(port: 0, announce: false)
        return (server, try #require(URL(string: "http://127.0.0.1:\(port)/mcp")), engine)
    }

    private func post(
        _ url: URL, body: [String: Any], headers: [String: String] = [:], httpMethod: String = "POST"
    ) async throws -> (status: Int, json: [String: Any]) {
        var request = URLRequest(url: url)
        request.httpMethod = httpMethod
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        if httpMethod == "POST" { request.httpBody = try JSONSerialization.data(withJSONObject: body) }
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = try #require((response as? HTTPURLResponse)?.statusCode)
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        return (status, json)
    }

    /// A modern request: `_meta` in the body plus the headers that mirror it. Both
    /// halves are built from the same values on purpose — a test that wants a mismatch
    /// overrides one side explicitly, so a mismatch is always visible in the test body.
    private func modern(
        method: String, params: [String: Any] = [:], version: String = MCPProtocol.latest,
        includeCapabilities: Bool = true
    ) -> (body: [String: Any], headers: [String: String]) {
        var meta: [String: Any] = [
            "io.modelcontextprotocol/protocolVersion": version,
            "io.modelcontextprotocol/clientInfo": ["name": "test-client", "version": "1.0"],
        ]
        if includeCapabilities { meta["io.modelcontextprotocol/clientCapabilities"] = [:] }
        var params = params
        params["_meta"] = meta
        var headers = ["MCP-Protocol-Version": version, "Mcp-Method": method]
        if let name = params["name"] as? String { headers["Mcp-Name"] = name }
        return (["jsonrpc": "2.0", "id": 1, "method": method, "params": params], headers)
    }

    /// A legacy request: no `_meta`, no mirrored headers — exactly what a `2025-06-18`
    /// client puts on the wire after its handshake.
    private func legacy(method: String, params: [String: Any] = [:]) -> [String: Any] {
        ["jsonrpc": "2.0", "id": 1, "method": method, "params": params]
    }

    private func error(_ json: [String: Any]) throws -> [String: Any] {
        try #require(json["error"] as? [String: Any], "expected a JSON-RPC error, got: \(json)")
    }

    private func result(_ json: [String: Any]) throws -> [String: Any] {
        try #require(json["result"] as? [String: Any], "expected a JSON-RPC result, got: \(json)")
    }

    // MARK: Legacy era — the regression surface

    /// The whole point of staying dual-era: a client on `2025-06-18` must see exactly
    /// what it saw before, including the absence of modern-only fields it would reject.
    @Test func legacyInitializeEchoesTheRequestedVersion() async throws {
        let (server, url, _) = try await startServer()
        defer { Task { await server.stop() } }

        let (status, json) = try await post(url, body: legacy(
            method: "initialize", params: ["protocolVersion": "2025-06-18"]
        ))

        #expect(status == 200)
        let result = try result(json)
        #expect(result["protocolVersion"] as? String == "2025-06-18")
        #expect(result["resultType"] == nil, "a legacy result must not carry the modern resultType")
        #expect((result["serverInfo"] as? [String: Any])?["name"] as? String == "loom")
    }

    /// A legacy client asking for a revision Loom doesn't serve is answered with the
    /// newest legacy one — it has no fall-forward mechanism, so leaving it to guess
    /// strands it.
    @Test func legacyInitializeFallsBackToTheNewestLegacyVersion() async throws {
        let (server, url, _) = try await startServer()
        defer { Task { await server.stop() } }

        let (_, json) = try await post(url, body: legacy(
            method: "initialize", params: ["protocolVersion": "2024-11-05"]
        ))

        #expect(try result(json)["protocolVersion"] as? String == MCPProtocol.latestLegacy)
    }

    /// A bare `tools/list` — no `_meta`, no headers — is a legacy client mid-session,
    /// not a malformed modern request. It must be served, and served *without* the
    /// modern additions.
    @Test func legacyToolsListIsServedWithoutModernFields() async throws {
        let (server, url, _) = try await startServer()
        defer { Task { await server.stop() } }

        let (status, json) = try await post(url, body: legacy(method: "tools/list"))

        #expect(status == 200)
        let result = try result(json)
        #expect((result["tools"] as? [[String: Any]])?.isEmpty == false)
        #expect(result["resultType"] == nil)
        #expect(result["ttlMs"] == nil, "caching hints are a modern-only result field")
        #expect(result["cacheScope"] == nil)
    }

    @Test func legacyToolsCallStillWorks() async throws {
        let (server, url, engine) = try await startServer()
        defer { Task { await server.stop() } }

        let (status, json) = try await post(url, body: legacy(
            method: "tools/call", params: ["name": "clear_flows", "arguments": [:]]
        ))

        #expect(status == 200)
        let result = try result(json)
        #expect(result["isError"] as? Bool == false)
        #expect(result["resultType"] == nil)
        #expect(engine.clearFlowsCallCount == 1)
    }

    /// Legacy errors stay on HTTP 200. That is how every client served here to date has
    /// read them, and the modern status codes below must not leak into this path.
    @Test func legacyErrorsStayOnHTTP200() async throws {
        let (server, url, _) = try await startServer()
        defer { Task { await server.stop() } }

        let (status, json) = try await post(url, body: legacy(method: "no/such/method"))

        #expect(status == 200)
        #expect(try error(json)["code"] as? Int == -32_601)
    }

    // MARK: Modern era

    @Test func modernToolsListCarriesResultTypeAndCachingHints() async throws {
        let (server, url, _) = try await startServer()
        defer { Task { await server.stop() } }

        let request = modern(method: "tools/list")
        let (status, json) = try await post(url, body: request.body, headers: request.headers)

        #expect(status == 200)
        let result = try result(json)
        #expect(result["resultType"] as? String == "complete")
        #expect((result["tools"] as? [[String: Any]])?.isEmpty == false)
        // Mandatory on a modern `complete` list result — and the reason a modern client
        // stops re-listing the registry every turn.
        #expect(result["ttlMs"] as? Int == MCPProtocol.listTTLMs)
        #expect(result["cacheScope"] as? String == "public")
        let meta = try #require(result["_meta"] as? [String: Any])
        let serverInfo = try #require(meta["io.modelcontextprotocol/serverInfo"] as? [String: Any])
        #expect(serverInfo["name"] as? String == "loom")
        #expect(serverInfo["version"] as? String == "9.9")
    }

    @Test func modernToolsCallRuns() async throws {
        let (server, url, engine) = try await startServer()
        defer { Task { await server.stop() } }

        let request = modern(method: "tools/call", params: ["name": "clear_flows", "arguments": [:]])
        let (status, json) = try await post(url, body: request.body, headers: request.headers)

        #expect(status == 200)
        let result = try result(json)
        #expect(result["resultType"] as? String == "complete")
        #expect(result["isError"] as? Bool == false)
        #expect(engine.clearFlowsCallCount == 1)
    }

    /// `server/discover` is how a client learns both eras exist in one round trip. It's
    /// answered in *either* era on purpose: a bare probe with no `_meta` still gets a
    /// real result, so a dual-era client discovers 2026-07-28 without guess-and-retry.
    @Test(arguments: [true, false])
    func discoverReportsBothEras(asModern: Bool) async throws {
        let (server, url, _) = try await startServer()
        defer { Task { await server.stop() } }

        let request = modern(method: "server/discover")
        let (status, json) = asModern
            ? try await post(url, body: request.body, headers: request.headers)
            : try await post(url, body: legacy(method: "server/discover"))

        #expect(status == 200)
        let result = try result(json)
        #expect(result["supportedVersions"] as? [String] == [MCPProtocol.latest, MCPProtocol.latestLegacy])
        let tools = try #require((result["capabilities"] as? [String: Any])?["tools"] as? [String: Any])
        #expect(tools["listChanged"] as? Bool == false)
        #expect(result["ttlMs"] as? Int == MCPProtocol.listTTLMs)
        #expect(result["cacheScope"] as? String == "public")
        #expect(result["instructions"] as? String != nil)
    }

    // MARK: Modern validation

    /// The renegotiation path. Without this error a modern client has no way to be told
    /// "not that revision, try one of these" — it is the entire downgrade mechanism.
    @Test func anUnsupportedModernVersionIsToldWhatIsSupported() async throws {
        let (server, url, _) = try await startServer()
        defer { Task { await server.stop() } }

        let request = modern(method: "tools/list", version: "1900-01-01")
        let (status, json) = try await post(url, body: request.body, headers: request.headers)

        #expect(status == 400)
        let error = try error(json)
        #expect(error["code"] as? Int == -32_022)
        let data = try #require(error["data"] as? [String: Any])
        #expect(data["supported"] as? [String] == [MCPProtocol.latest, MCPProtocol.latestLegacy])
        #expect(data["requested"] as? String == "1900-01-01")
    }

    @Test func aModernRequestMissingClientCapabilitiesIsRejected() async throws {
        let (server, url, _) = try await startServer()
        defer { Task { await server.stop() } }

        let request = modern(method: "tools/list", includeCapabilities: false)
        let (status, json) = try await post(url, body: request.body, headers: request.headers)

        #expect(status == 400)
        #expect(try error(json)["code"] as? Int == -32_602)
    }

    /// Header ↔ body disagreement is `-32020` because a gateway routing on the header
    /// while the server executes the body is a split brain, not a nit.
    @Test func aVersionHeaderThatDisagreesWithTheBodyIsRejected() async throws {
        let (server, url, _) = try await startServer()
        defer { Task { await server.stop() } }

        var request = modern(method: "tools/list")
        request.headers["MCP-Protocol-Version"] = "2025-11-25"
        let (status, json) = try await post(url, body: request.body, headers: request.headers)

        #expect(status == 400)
        #expect(try error(json)["code"] as? Int == -32_020)
    }

    @Test func aModernRequestWithoutTheVersionHeaderIsRejected() async throws {
        let (server, url, _) = try await startServer()
        defer { Task { await server.stop() } }

        var request = modern(method: "tools/list")
        request.headers.removeValue(forKey: "MCP-Protocol-Version")
        let (status, json) = try await post(url, body: request.body, headers: request.headers)

        #expect(status == 400)
        #expect(try error(json)["code"] as? Int == -32_020)
    }

    @Test func anMcpMethodHeaderThatDisagreesWithTheBodyIsRejected() async throws {
        let (server, url, _) = try await startServer()
        defer { Task { await server.stop() } }

        var request = modern(method: "tools/list")
        request.headers["Mcp-Method"] = "tools/call"
        let (status, json) = try await post(url, body: request.body, headers: request.headers)

        #expect(status == 400)
        #expect(try error(json)["code"] as? Int == -32_020)
    }

    /// The security-relevant one: a gateway that authorized `Mcp-Name: get_recent_flows`
    /// must not be able to have `clear_flows` executed underneath it.
    @Test func anMcpNameHeaderThatDisagreesWithTheBodyIsRejectedWithoutRunningTheTool() async throws {
        let (server, url, engine) = try await startServer()
        defer { Task { await server.stop() } }

        var request = modern(method: "tools/call", params: ["name": "clear_flows", "arguments": [:]])
        request.headers["Mcp-Name"] = "get_recent_flows"
        let (status, json) = try await post(url, body: request.body, headers: request.headers)

        #expect(status == 400)
        #expect(try error(json)["code"] as? Int == -32_020)
        #expect(engine.clearFlowsCallCount == 0, "the body's tool ran despite the header naming another")
    }

    @Test func aToolsCallWithoutAnMcpNameHeaderIsRejected() async throws {
        let (server, url, engine) = try await startServer()
        defer { Task { await server.stop() } }

        var request = modern(method: "tools/call", params: ["name": "clear_flows", "arguments": [:]])
        request.headers.removeValue(forKey: "Mcp-Name")
        let (status, json) = try await post(url, body: request.body, headers: request.headers)

        #expect(status == 400)
        #expect(try error(json)["code"] as? Int == -32_020)
        #expect(engine.clearFlowsCallCount == 0)
    }

    /// A name that can't ride in a plain header travels Base64-sentinel-encoded, and the
    /// server must decode before comparing — otherwise an encoded name never matches its
    /// body value and the tool is unreachable. Loom's own names are all ASCII, so this
    /// pins the decoder rather than a real tool.
    @Test func aBase64SentinelNameHeaderIsDecodedBeforeComparison() async throws {
        let (server, url, engine) = try await startServer()
        defer { Task { await server.stop() } }

        var request = modern(method: "tools/call", params: ["name": "clear_flows", "arguments": [:]])
        request.headers["Mcp-Name"] = "=?base64?\(Data("clear_flows".utf8).base64EncodedString())?="
        let (status, _) = try await post(url, body: request.body, headers: request.headers)

        #expect(status == 200)
        #expect(engine.clearFlowsCallCount == 1)
    }

    /// The era-ambiguity trap, and the reason the pre-fix server was dangerous: a header
    /// claiming a modern revision over a body with no `_meta` must be reported as a
    /// mismatch, not quietly served under legacy rules. A client told "modern" by a
    /// gateway and "legacy" by us is how the two end up disagreeing about what ran.
    @Test func aModernVersionHeaderOverALegacyBodyIsAMismatch() async throws {
        let (server, url, _) = try await startServer()
        defer { Task { await server.stop() } }

        let (status, json) = try await post(
            url, body: legacy(method: "tools/list"),
            headers: ["MCP-Protocol-Version": MCPProtocol.latest, "Mcp-Method": "tools/list"]
        )

        #expect(status == 400)
        #expect(try error(json)["code"] as? Int == -32_020)
    }

    // MARK: Modern status codes

    /// `404` + a JSON-RPC error body is what distinguishes "this server doesn't have
    /// that method" from "this isn't an MCP endpoint at all", which is the signal a
    /// dual-era client uses to decide whether to fall back.
    @Test func anUnknownModernMethodIs404() async throws {
        let (server, url, _) = try await startServer()
        defer { Task { await server.stop() } }

        let request = modern(method: "no/such/method")
        let (status, json) = try await post(url, body: request.body, headers: request.headers)

        #expect(status == 404)
        #expect(try error(json)["code"] as? Int == -32_601)
    }

    /// An unknown *tool* is a bad parameter, not a missing method — `tools/call` exists.
    @Test func anUnknownToolIsInvalidParamsNotMethodNotFound() async throws {
        let (server, url, _) = try await startServer()
        defer { Task { await server.stop() } }

        let request = modern(method: "tools/call", params: ["name": "no_such_tool", "arguments": [:]])
        let (status, json) = try await post(url, body: request.body, headers: request.headers)

        #expect(status == 400)
        #expect(try error(json)["code"] as? Int == -32_602)
    }

    // MARK: Transport

    /// GET and DELETE were the old transport's standalone SSE stream and session
    /// teardown. `2026-07-28` dropped both and requires `405` — distinguishable from the
    /// `404` of an endpoint that isn't there.
    @Test(arguments: ["GET", "DELETE"])
    func theRemovedSessionVerbsAre405(httpMethod: String) async throws {
        let (server, url, _) = try await startServer()
        defer { Task { await server.stop() } }

        let (status, _) = try await post(url, body: [:], httpMethod: httpMethod)

        #expect(status == 405)
    }

    @Test func anUnknownPathIsStill404() async throws {
        let (server, url, _) = try await startServer()
        defer { Task { await server.stop() } }

        let other = try #require(URL(string: url.absoluteString.replacingOccurrences(of: "/mcp", with: "/nope")))
        let (status, _) = try await post(other, body: legacy(method: "tools/list"))

        #expect(status == 404)
    }
}
