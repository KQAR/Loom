import Foundation
import LoomSharedModels
import Testing

@testable import MCPServer

/// The agent's half of the whitelist scope.
///
/// With `include` empty, "the client made no requests" and "Loom passed everything
/// through unread" produce the same empty `get_recent_flows`. `get_ssl_scope` is
/// where that stops being ambiguous, and `intercept_host` is the one-call fix — so
/// what these pin is mostly *what the reply says*, because the reply is the only
/// thing standing between an agent and a wrong conclusion.
@MainActor
@Suite("SSL scope discovery tools")
struct SSLScopeDiscoveryToolTests {
    private func makeExecutor(_ engine: StubEngine) -> MCPToolExecutor {
        MCPToolExecutor(engine: engine, appVersion: "9.9", protocolVersion: "2025-06-18")
    }

    private func decode(_ json: String) throws -> [String: Any] {
        let object = try JSONSerialization.jsonObject(with: Data(json.utf8))
        return try #require(object as? [String: Any])
    }

    // MARK: get_ssl_scope

    @Test func getSSLScope_carriesTunneledHosts_soOneCallExplainsAnEmptyCapture() async throws {
        let engine = StubEngine()
        engine.scope = SSLScope(enabled: true, include: [])
        engine.tunneled = TunneledHostReport(
            hosts: [
                TunneledHost(
                    host: "grafana.example.com", port: 443, connections: 7,
                    firstSeen: Date(timeIntervalSince1970: 100),
                    lastSeen: Date(timeIntervalSince1970: 700), reason: .notInScope
                ),
                TunneledHost(
                    host: "ssh.example.com", port: 22,
                    firstSeen: Date(timeIntervalSince1970: 100),
                    lastSeen: Date(timeIntervalSince1970: 200), reason: .notTLSOrHTTP
                ),
            ],
            evicted: 3,
            clientSuccessesEvicted: 4
        )

        let payload = try decode(try await makeExecutor(engine).call(name: "get_ssl_scope", arguments: [:]))
        let hosts = try #require(payload["tunneledHosts"] as? [[String: Any]])
        #expect(hosts.count == 2)

        let first = hosts[0]
        #expect(first["host"] as? String == "grafana.example.com")
        #expect(first["connections"] as? Int == 7)
        #expect(first["reason"] as? String == "notInScope")
        // Carried rather than inferred from `reason`, so the follow-up action is
        // decidable from the row alone.
        #expect(first["interceptable"] as? Bool == true)
        #expect(hosts[1]["interceptable"] as? Bool == false)
        // Truncation is never silent, here as everywhere else in Loom.
        #expect(payload["tunneledHostsEvicted"] as? Int == 3)
        #expect(payload["clientTLSSuccessesEvicted"] as? Int == 4)
    }

    @Test func getSSLScope_omitsTheKeysEntirelyWhenNothingWasTunneled() async throws {
        let engine = StubEngine()
        let payload = try decode(try await makeExecutor(engine).call(name: "get_ssl_scope", arguments: [:]))
        #expect(payload["tunneledHosts"] == nil)
        #expect(payload["tunneledHostsEvicted"] == nil)
        #expect(payload["enabled"] != nil, "the scope itself is always reported")
    }

    @Test func mixedHandshakeOutcomesKeepBothCountsAndLatestResult() async throws {
        let engine = StubEngine()
        engine.tunneled = TunneledHostReport(hosts: [
            TunneledHost(
                host: "cdn.example.com",
                port: 443,
                connections: 76,
                firstSeen: Date(timeIntervalSince1970: 100),
                lastSeen: Date(timeIntervalSince1970: 200),
                reason: .clientHandshakeFailed,
                detail: "certificate_unknown",
                clientTLS: TunneledHost.ClientTLS(
                    failureCount: 76,
                    successCount: 1,
                    lastFailureAt: Date(timeIntervalSince1970: 190),
                    lastSuccessAt: Date(timeIntervalSince1970: 200),
                    lastFailureCode: .clientCertificateRejected
                )
            ),
        ])

        let payload = try decode(
            try await makeExecutor(engine).call(name: "get_ssl_scope", arguments: [:])
        )
        let host = try #require(
            (payload["tunneledHosts"] as? [[String: Any]])?.first
        )
        let clientTLS = try #require(host["clientTLS"] as? [String: Any])
        #expect(clientTLS["status"] as? String == "mixed")
        #expect(clientTLS["latestResult"] as? String == "succeeded")
        #expect(clientTLS["failureCount"] as? Int == 76)
        #expect(clientTLS["successCount"] as? Int == 1)
        #expect(clientTLS["lastFailureCode"] as? String == "clientCertificateRejected")
    }

    // MARK: intercept_host

    @Test func interceptHost_reportsWhatItTook_andTheResultingScope() async throws {
        let engine = StubEngine()
        engine.scope = .disabled

        let payload = try decode(try await makeExecutor(engine).call(
            name: "intercept_host", arguments: ["host": "api.example.com"]
        ))
        #expect(payload["effective"] as? Bool == true)
        #expect(payload["alreadyIncluded"] as? Bool == false)
        // Turning interception on is a change the caller did not literally ask for.
        #expect(payload["enabledInterception"] as? Bool == true)
        let scope = try #require(payload["scope"] as? [String: Any])
        #expect(scope["include"] as? [String] == ["api.example.com"])
        #expect(engine.interceptedHosts == ["api.example.com"])
    }

    /// The write lands, `include` shows the host, and the traffic is still unread.
    /// Reporting this as success is the specific mistake worth a test.
    @Test func interceptHost_shadowedByExclude_isNotEffective_andSaysWhy() async throws {
        let engine = StubEngine()
        engine.scope = SSLScope(enabled: true, exclude: ["*.example.com"])

        let payload = try decode(try await makeExecutor(engine).call(
            name: "intercept_host", arguments: ["host": "api.example.com"]
        ))
        #expect(payload["effective"] as? Bool == false)
        #expect(payload["shadowedByExclude"] as? String == "*.example.com")
        let detail = try #require(payload["detail"] as? String)
        #expect(detail.contains("*.example.com"))
    }

    @Test func interceptHost_requiresAHost() async throws {
        let engine = StubEngine()
        await #expect(throws: MCPToolFailure.self) {
            _ = try await makeExecutor(engine).call(name: "intercept_host", arguments: ["host": "   "])
        }
    }

    // MARK: Registry

    /// A write tool that isn't audited, or is advertised without saying so to the
    /// agent, are both states the registry can otherwise be in.
    @Test func interceptHost_isAWriteTool_advertisedAsOne_andAudited() async throws {
        let engine = StubEngine()
        let executor = makeExecutor(engine)
        let tool = try #require(MCPToolExecutor.tools.first { $0.name == "intercept_host" })
        #expect(tool.isWrite)
        #expect(tool.description.contains("This is a write action."))
        #expect(MCPToolExecutor.writeTools.contains("intercept_host"))

        _ = try await executor.call(name: "intercept_host", arguments: ["host": "api.example.com"])
        #expect(engine.recordedAudits.contains { $0.tool == "intercept_host" })
    }

    @Test func getSSLScope_staysAReadTool() {
        let tool = MCPToolExecutor.tools.first { $0.name == "get_ssl_scope" }
        #expect(tool?.isWrite == false)
        #expect(!MCPToolExecutor.writeTools.contains("get_ssl_scope"))
    }
}
