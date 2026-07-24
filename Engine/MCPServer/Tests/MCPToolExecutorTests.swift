import Testing
import Foundation
import LoomSharedModels
@testable import MCPServer

/// Behavior contract for `MCPToolExecutor`, pinned before the registry refactor:
/// every advertised tool is dispatchable, argument validation stays strict, and
/// the executor forwards writes to the engine and renders results as JSON.
@Suite struct MCPToolExecutorTests {
    private func makeExecutor(_ engine: StubEngine = StubEngine()) -> MCPToolExecutor {
        MCPToolExecutor(engine: engine, appVersion: "9.9", protocolVersion: "2025-06-18")
    }

    private func json(_ string: String) throws -> [String: Any] {
        let data = Data(string.utf8)
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func jsonArray(_ string: String) throws -> [[String: Any]] {
        let data = Data(string.utf8)
        return try #require(try JSONSerialization.jsonObject(with: data) as? [[String: Any]])
    }

    // MARK: Registry consistency — the drift guard the refactor must preserve

    @Test func everyAdvertisedTool_isDispatchable() async {
        let executor = makeExecutor()
        let names = executor.toolDefinitions.compactMap { $0["name"] as? String }
        #expect(names.count >= 16)
        #expect(Set(names).count == names.count, "tool names must be unique")
        for name in names {
            if name == "export_har" { continue } // writes a real file to the app-support dir
            do {
                _ = try await executor.call(name: name, arguments: [:])
            } catch let error as MCPError {
                // Missing required args are fine; "unknown tool" means the schema
                // advertises a tool with no handler — the drift bug we guard against.
                if case let .methodNotFound(message) = error {
                    Issue.record("advertised tool \(name) has no handler: \(message)")
                }
            } catch {
                // MCPToolFailure / other domain errors are acceptable for empty args.
            }
        }
    }

    @Test func handlerRegistry_exactlyMatchesAdvertisedTools() {
        let advertised = Set(makeExecutor().toolDefinitions.compactMap { $0["name"] as? String })
        let handled = Set(MCPToolExecutor.handlers.keys)
        #expect(advertised == handled, "every advertised tool has a handler and vice-versa")
    }

    @Test func unknownTool_throwsMethodNotFound() async {
        do {
            _ = try await makeExecutor().call(name: "does_not_exist", arguments: [:])
            Issue.record("expected methodNotFound")
        } catch let error as MCPError {
            guard case .methodNotFound = error else { Issue.record("wrong error: \(error)"); return }
        } catch { Issue.record("wrong error type: \(error)") }
    }

    @Test func listDevices_rendersEngineDevices() async throws {
        let engine = StubEngine()
        engine.devices = [
            DeviceSummary(
                device: SourceDevice(ip: "192.168.1.37", kind: .lan, platform: "iOS", client: "Safari"),
                flowCount: 3, lastActive: Date(timeIntervalSince1970: 1_700_000_000)
            ),
            DeviceSummary(
                device: SourceDevice(ip: "127.0.0.1", kind: .local, platform: "macOS", client: "Chrome"),
                flowCount: 10, lastActive: Date(timeIntervalSince1970: 1_700_000_100)
            ),
        ]
        let out = try await makeExecutor(engine).call(name: "list_devices", arguments: [:])
        let devices = try jsonArray(out)
        #expect(devices.count == 2)

        let lan = try #require(devices.first { $0["ip"] as? String == "192.168.1.37" })
        #expect(lan["kind"] as? String == "lan")
        #expect(lan["platform"] as? String == "iOS")
        #expect(lan["client"] as? String == "Safari")
        #expect(lan["type"] as? String == "Safari (iOS)")
        #expect(lan["flowCount"] as? Int == 3)
    }

    // MARK: Read tools

    @Test func getVersion() async throws {
        let out = try json(try await makeExecutor().call(name: "get_version", arguments: [:]))
        #expect(out["app"] as? String == "Loom")
        #expect(out["appVersion"] as? String == "9.9")
    }

    @Test func getRecentFlows_rendersSummaries() async throws {
        let engine = StubEngine()
        engine.flows = [Fixtures.completedFlow(url: "https://a/1"), Fixtures.completedFlow(url: "https://b/2")]
        let out = try jsonArray(try await makeExecutor(engine).call(name: "get_recent_flows", arguments: ["limit": 10]))
        #expect(out.count == 2)
        #expect(out.first?["url"] as? String == "https://a/1")
    }

    @Test func getFlowDetail_includesHTTPVersion() async throws {
        let engine = StubEngine()
        let flow = Fixtures.completedFlow(url: "https://a/1", httpVersion: "HTTP/2")
        engine.flows = [flow]
        let out = try json(try await makeExecutor(engine).call(name: "get_flow_detail", arguments: ["id": flow.id.uuidString]))
        let response = try #require(out["response"] as? [String: Any])
        #expect(response["httpVersion"] as? String == "HTTP/2")
    }

    @Test func getFlowDetail_unknownID_isToolFailure() async {
        do {
            _ = try await makeExecutor().call(name: "get_flow_detail", arguments: ["id": UUID().uuidString])
            Issue.record("expected failure")
        } catch is MCPToolFailure {
            // expected: in-band tool failure, not a JSON-RPC error
        } catch { Issue.record("expected MCPToolFailure, got \(error)") }
    }

    @Test func getFlowDetail_badID_isInvalidParams() async {
        do {
            _ = try await makeExecutor().call(name: "get_flow_detail", arguments: ["id": "not-a-uuid"])
            Issue.record("expected invalidParams")
        } catch let error as MCPError {
            guard case .invalidParams = error else { Issue.record("wrong error: \(error)"); return }
        } catch { Issue.record("wrong error type: \(error)") }
    }

    @Test func diffFlows_explicitPair_rendersDiff() async throws {
        let engine = StubEngine()
        let base = Fixtures.completedFlow(url: "https://a/1")
        var compared = Fixtures.completedFlow(url: "https://a/1")
        compared.outcome = .completed(
            CapturedResponse(statusCode: 500, httpVersion: "HTTP/1.1", headers: [], body: Data("{}".utf8)),
            at: Date(timeIntervalSince1970: 1_000.1)
        )
        engine.flows = [base, compared]
        let out = try json(try await makeExecutor(engine).call(name: "diff_flows", arguments: [
            "base": base.id.uuidString, "compared": compared.id.uuidString,
        ]))
        #expect(out["identical"] as? Bool == false)
        let status = try #require((out["response"] as? [String: Any])?["status"] as? [String: Any])
        #expect(status["base"] as? Int == 200)
        #expect(status["compared"] as? Int == 500)
    }

    @Test func diffFlows_baseOnly_usesReplayedFrom() async throws {
        let engine = StubEngine()
        let original = Fixtures.completedFlow(url: "https://a/1")
        var replay = Fixtures.completedFlow(url: "https://a/1")
        replay.replayedFrom = original.id
        replay.request.method = "POST"
        engine.flows = [original, replay]
        let out = try json(try await makeExecutor(engine).call(name: "diff_flows", arguments: [
            "base": replay.id.uuidString,
        ]))
        #expect(out["baseId"] as? String == original.id.uuidString)
        #expect(out["comparedId"] as? String == replay.id.uuidString)
        let method = try #require((out["request"] as? [String: Any])?["method"] as? [String: Any])
        #expect(method["compared"] as? String == "POST")
    }

    @Test func diffFlows_baseOnly_noReplayLink_isToolFailure() async {
        let engine = StubEngine()
        let lone = Fixtures.completedFlow(url: "https://a/1")
        engine.flows = [lone]
        do {
            _ = try await makeExecutor(engine).call(name: "diff_flows", arguments: ["base": lone.id.uuidString])
            Issue.record("expected tool failure")
        } catch is MCPToolFailure {
        } catch { Issue.record("expected MCPToolFailure, got \(error)") }
    }

    @Test func diffFlows_missingBase_isInvalidParams() async {
        do {
            _ = try await makeExecutor().call(name: "diff_flows", arguments: [:])
            Issue.record("expected invalidParams")
        } catch let error as MCPError {
            guard case .invalidParams = error else { Issue.record("wrong error: \(error)"); return }
        } catch { Issue.record("wrong error type: \(error)") }
    }

    // MARK: Breakpoints

    @Test func armBreakpoint_forwardsToEngine() async throws {
        let engine = StubEngine()
        let out = try json(try await makeExecutor(engine).call(name: "arm_breakpoint", arguments: [
            "match": ["url_pattern": "https://api.example.com/*"],
            "on_response": true,
        ]))
        #expect(UUID(uuidString: out["id"] as? String ?? "") != nil)
        #expect(out["onRequest"] as? Bool == true)
        #expect(out["onResponse"] as? Bool == true)
        #expect(engine.armed.count == 1)
    }

    @Test func armBreakpoint_missingMatch_isInvalidParams() async {
        do {
            _ = try await makeExecutor().call(name: "arm_breakpoint", arguments: ["on_request": true])
            Issue.record("expected invalidParams")
        } catch let error as MCPError {
            guard case .invalidParams = error else { Issue.record("wrong error: \(error)"); return }
        } catch { Issue.record("wrong error type: \(error)") }
    }

    @Test func listPending_rendersArmedAndPending() async throws {
        let engine = StubEngine()
        engine.armed = [Breakpoint(match: RuleMatch(urlPattern: "*"))]
        engine.pending = [PendingBreakpoint(
            breakpointID: UUID(), phase: .request,
            method: "GET", url: "https://a/1", requestHeaders: [], requestBody: Data("hi".utf8)
        )]
        let out = try json(try await makeExecutor(engine).call(name: "list_pending", arguments: [:]))
        #expect((out["armed"] as? [[String: Any]])?.count == 1)
        let pending = try #require(out["pending"] as? [[String: Any]])
        #expect(pending.count == 1)
        #expect((pending.first?["request"] as? [String: Any])?["method"] as? String == "GET")
    }

    @Test func resume_forwardsEditsToEngine() async throws {
        let engine = StubEngine()
        let held = PendingBreakpoint(
            breakpointID: UUID(), phase: .response,
            method: "GET", url: "https://a/1", requestHeaders: []
        )
        engine.pending = [held]
        _ = try await makeExecutor(engine).call(name: "resume", arguments: [
            "pending_id": held.id.uuidString,
            "status_code": 503,
            "body": "down",
        ])
        let call = try #require(engine.resumeCalls.first)
        #expect(call.id == held.id)
        #expect(!(call.abort))
        #expect(call.edit.statusCode == 503)
        #expect(call.edit.body == .replace(Data("down".utf8)))
    }

    @Test func resume_unknownPendingID_isToolFailure() async {
        do {
            _ = try await makeExecutor().call(name: "resume", arguments: ["pending_id": UUID().uuidString])
            Issue.record("expected tool failure")
        } catch is MCPToolFailure {
        } catch { Issue.record("expected MCPToolFailure, got \(error)") }
    }

    @Test func disarmBreakpoint_unknownID_isToolFailure() async {
        do {
            _ = try await makeExecutor().call(name: "disarm_breakpoint", arguments: ["id": UUID().uuidString])
            Issue.record("expected tool failure")
        } catch is MCPToolFailure {
        } catch { Issue.record("expected MCPToolFailure, got \(error)") }
    }

    // MARK: Write tools forward to the engine

    @Test func replayFlow_forwardsAndRendersFailureInBand() async throws {
        let engine = StubEngine()
        engine.replayError = ProxyControlError.replayFailed("boom")
        do {
            _ = try await makeExecutor(engine).call(name: "replay_flow", arguments: ["id": UUID().uuidString])
            Issue.record("expected tool failure")
        } catch let failure as MCPToolFailure {
            #expect(failure.message.contains("boom"))
        }
        #expect(engine.lastReplay != nil)
    }

    @Test func setSSLScope_mergesAndForwards() async throws {
        let engine = StubEngine()
        _ = try await makeExecutor(engine).call(name: "set_ssl_scope", arguments: [
            "enabled": true, "include": ["*.example.com"],
        ])
        #expect(engine.lastSSLScope?.enabled == true)
        #expect(engine.lastSSLScope?.include == ["*.example.com"])
    }

    @Test func setRule_create_strictParse_missingMatch_isInvalidParams() async {
        do {
            _ = try await makeExecutor().call(name: "set_rule", arguments: [
                "name": "r", "actions": ["block": true],
            ])
            Issue.record("expected invalidParams for missing match")
        } catch let error as MCPError {
            guard case .invalidParams = error else { Issue.record("wrong error: \(error)"); return }
        } catch { Issue.record("wrong error type: \(error)") }
    }

    @Test func setRule_noID_createsRule() async throws {
        let engine = StubEngine()
        let out = try json(try await makeExecutor(engine).call(name: "set_rule", arguments: [
            "name": "block home",
            "match": ["url_pattern": "https://api.example.com/home"],
            "actions": ["block": true],
        ]))
        #expect(out["name"] as? String == "block home")
        #expect(engine.addedRules.count == 1)
        #expect(engine.rules.rules.count == 1)
    }

    @Test func setRule_withID_updatesExistingRule() async throws {
        let engine = StubEngine()
        let existing = TrafficRule(name: "old", match: RuleMatch(urlPattern: "https://a/*"),
                                   actions: RuleActions(route: .block))
        engine.rules.rules = [existing]
        _ = try await makeExecutor(engine).call(name: "set_rule", arguments: [
            "id": existing.id.uuidString, "name": "renamed", "enabled": false,
        ])
        let updated = try #require(engine.rules.rules.first { $0.id == existing.id })
        #expect(updated.name == "renamed")
        #expect(updated.isEnabled == false)
        #expect(engine.addedRules.isEmpty, "update must not go through the create path")
    }

    @Test func setRule_withUnknownID_isToolFailure() async {
        do {
            _ = try await makeExecutor().call(name: "set_rule", arguments: [
                "id": UUID().uuidString, "name": "x",
            ])
            Issue.record("expected tool failure")
        } catch is MCPToolFailure {
        } catch { Issue.record("expected MCPToolFailure, got \(error)") }
    }

    @Test func listRules_withID_returnsSingleFullRule() async throws {
        let engine = StubEngine()
        let rule = TrafficRule(name: "only", match: RuleMatch(urlPattern: "https://a/*"),
                               actions: RuleActions(route: .block))
        engine.rules.rules = [rule]
        // No id → collection with a count; id → the single rule object.
        let all = try json(try await makeExecutor(engine).call(name: "list_rules", arguments: [:]))
        #expect(all["count"] as? Int == 1)
        let one = try json(try await makeExecutor(engine).call(name: "list_rules", arguments: ["id": rule.id.uuidString]))
        #expect(one["name"] as? String == "only")
        #expect(one["count"] == nil, "single-rule form isn't the list envelope")
    }

    @Test func deleteRule_unknownID_isToolFailure() async {
        do {
            _ = try await makeExecutor().call(name: "delete_rule", arguments: ["id": UUID().uuidString])
            Issue.record("expected failure")
        } catch is MCPToolFailure {
        } catch { Issue.record("expected MCPToolFailure, got \(error)") }
    }

    @Test func setRulesEnabled_requiresBool() async {
        do {
            _ = try await makeExecutor().call(name: "set_rules_enabled", arguments: [:])
            Issue.record("expected invalidParams")
        } catch let error as MCPError {
            guard case .invalidParams = error else { Issue.record("wrong error: \(error)"); return }
        } catch { Issue.record("wrong error type: \(error)") }
    }

    // MARK: Write-action audit log

    /// The audited set must match exactly the tools whose definition is marked
    /// "This is a write action." — a marker and a missed audit can't diverge.
    @Test func writeToolSet_matchesMarkedDefinitions() {
        // Match without the trailing period: some markers read "This is a write
        // action (writes a file)." rather than "…action.".
        let marked = Set(makeExecutor().toolDefinitions
            .filter { ($0["description"] as? String)?.contains("This is a write action") == true }
            .compactMap { $0["name"] as? String })
        #expect(marked == MCPToolExecutor.writeTools,
                "every write-marked tool is audited and vice-versa; diff: \(marked.symmetricDifference(MCPToolExecutor.writeTools))")
    }

    @Test func writeTool_success_recordsAuditEntry() async throws {
        let engine = StubEngine()
        _ = try await makeExecutor(engine).call(name: "set_rule", arguments: [
            "name": "block home",
            "match": ["url_pattern": "https://api.example.com/home"],
            "actions": ["block": true],
        ])
        let entry = try #require(engine.recordedAudits.first)
        #expect(engine.recordedAudits.count == 1)
        #expect(entry.tool == "set_rule")
        #expect(entry.source == .mcp)
        #expect(entry.succeeded)
        #expect(entry.arguments.contains("block home"))
    }

    @Test func writeTool_failure_recordsFailedAuditEntry_andStillThrows() async {
        let engine = StubEngine()
        engine.replayError = ProxyControlError.replayFailed("boom")
        do {
            _ = try await makeExecutor(engine).call(name: "replay_flow", arguments: ["id": UUID().uuidString])
            Issue.record("expected the failure to propagate")
        } catch is MCPToolFailure {
            // expected — the audit record must not swallow the error
        } catch { Issue.record("unexpected error: \(error)") }
        #expect(engine.recordedAudits.count == 1)
        let entry = engine.recordedAudits.first
        #expect(entry?.tool == "replay_flow")
        #expect(entry?.succeeded == false)
        #expect(entry?.detail.contains("boom") == true)
    }

    @Test func readTool_isNotAudited() async throws {
        let engine = StubEngine()
        engine.flows = [Fixtures.completedFlow(url: "https://a/1")]
        _ = try await makeExecutor(engine).call(name: "get_recent_flows", arguments: [:])
        _ = try await makeExecutor(engine).call(name: "get_audit_log", arguments: [:])
        #expect(engine.recordedAudits.isEmpty, "read tools must never be audited")
    }

    @Test func getAuditLog_rendersEntriesNewestFirst() async throws {
        let engine = StubEngine()
        await engine.recordAudit(AuditEntry(
            timestamp: Date(timeIntervalSince1970: 1_000), tool: "create_rule",
            succeeded: true, arguments: #"{"name":"a"}"#, detail: "ok"
        ))
        await engine.recordAudit(AuditEntry(
            timestamp: Date(timeIntervalSince1970: 2_000), tool: "delete_rule",
            succeeded: false, arguments: #"{"id":"x"}"#, detail: "no rule"
        ))
        let out = try jsonArray(try await makeExecutor(engine).call(name: "get_audit_log", arguments: [:]))
        #expect(out.count == 2)
        #expect(out.first?["tool"] as? String == "delete_rule") // newest first
        #expect(out.first?["succeeded"] as? Bool == false)
        #expect(out.first?["detail"] as? String == "no rule")
        #expect(out.last?["tool"] as? String == "create_rule")
    }

    @Test func auditArguments_areTruncatedToCap() async throws {
        let engine = StubEngine()
        let huge = String(repeating: "x", count: AuditEntry.cap + 500)
        // A set_rule whose name is oversized — the args render must clip.
        _ = try? await makeExecutor(engine).call(name: "set_rule", arguments: [
            "name": huge,
            "match": ["url_pattern": "https://a/*"],
            "actions": ["block": true],
        ])
        let entry = try #require(engine.recordedAudits.first)
        #expect(entry.arguments.count <= AuditEntry.cap + 40) // cap + the "… (N more)" marker
        #expect(entry.arguments.contains("more chars)"))
    }
}

private enum Fixtures {
    static func completedFlow(url: String, httpVersion: String? = "HTTP/1.1") -> Flow {
        Flow(
            id: UUID(),
            request: CapturedRequest(method: "GET", url: url, headers: []),
            startedAt: Date(timeIntervalSince1970: 1_000),
            outcome: .completed(
                CapturedResponse(statusCode: 200, httpVersion: httpVersion, headers: [], body: Data("{}".utf8)),
                at: Date(timeIntervalSince1970: 1_000.1)
            )
        )
    }
}
