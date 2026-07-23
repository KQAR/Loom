import XCTest
import SharedModels
@testable import MCPServer

/// Behavior contract for `MCPToolExecutor`, pinned before the registry refactor:
/// every advertised tool is dispatchable, argument validation stays strict, and
/// the executor forwards writes to the engine and renders results as JSON.
final class MCPToolExecutorTests: XCTestCase {
    private func makeExecutor(_ engine: StubEngine = StubEngine()) -> MCPToolExecutor {
        MCPToolExecutor(engine: engine, appVersion: "9.9", protocolVersion: "2025-06-18")
    }

    private func json(_ string: String) throws -> [String: Any] {
        let data = Data(string.utf8)
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func jsonArray(_ string: String) throws -> [[String: Any]] {
        let data = Data(string.utf8)
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [[String: Any]])
    }

    // MARK: Registry consistency — the drift guard the refactor must preserve

    func test_everyAdvertisedTool_isDispatchable() async {
        let executor = makeExecutor()
        let names = executor.toolDefinitions.compactMap { $0["name"] as? String }
        XCTAssertGreaterThanOrEqual(names.count, 16)
        XCTAssertEqual(Set(names).count, names.count, "tool names must be unique")
        for name in names {
            if name == "export_har" { continue } // writes a real file to the app-support dir
            do {
                _ = try await executor.call(name: name, arguments: [:])
            } catch let error as MCPError {
                // Missing required args are fine; "unknown tool" means the schema
                // advertises a tool with no handler — the drift bug we guard against.
                if case let .methodNotFound(message) = error {
                    XCTFail("advertised tool \(name) has no handler: \(message)")
                }
            } catch {
                // MCPToolFailure / other domain errors are acceptable for empty args.
            }
        }
    }

    func test_handlerRegistry_exactlyMatchesAdvertisedTools() {
        let advertised = Set(makeExecutor().toolDefinitions.compactMap { $0["name"] as? String })
        let handled = Set(MCPToolExecutor.handlers.keys)
        XCTAssertEqual(advertised, handled, "every advertised tool has a handler and vice-versa")
    }

    func test_unknownTool_throwsMethodNotFound() async {
        do {
            _ = try await makeExecutor().call(name: "does_not_exist", arguments: [:])
            XCTFail("expected methodNotFound")
        } catch let error as MCPError {
            guard case .methodNotFound = error else { return XCTFail("wrong error: \(error)") }
        } catch { XCTFail("wrong error type: \(error)") }
    }

    // MARK: Read tools

    func test_getVersion() async throws {
        let out = try json(try await makeExecutor().call(name: "get_version", arguments: [:]))
        XCTAssertEqual(out["app"] as? String, "Loom")
        XCTAssertEqual(out["appVersion"] as? String, "9.9")
    }

    func test_getRecentFlows_rendersSummaries() async throws {
        let engine = StubEngine()
        engine.flows = [Fixtures.completedFlow(url: "https://a/1"), Fixtures.completedFlow(url: "https://b/2")]
        let out = try jsonArray(try await makeExecutor(engine).call(name: "get_recent_flows", arguments: ["limit": 10]))
        XCTAssertEqual(out.count, 2)
        XCTAssertEqual(out.first?["url"] as? String, "https://a/1")
    }

    func test_getFlowDetail_includesHTTPVersion() async throws {
        let engine = StubEngine()
        let flow = Fixtures.completedFlow(url: "https://a/1", httpVersion: "HTTP/2")
        engine.flows = [flow]
        let out = try json(try await makeExecutor(engine).call(name: "get_flow_detail", arguments: ["id": flow.id.uuidString]))
        let response = try XCTUnwrap(out["response"] as? [String: Any])
        XCTAssertEqual(response["httpVersion"] as? String, "HTTP/2")
    }

    func test_getFlowDetail_unknownID_isToolFailure() async {
        do {
            _ = try await makeExecutor().call(name: "get_flow_detail", arguments: ["id": UUID().uuidString])
            XCTFail("expected failure")
        } catch is MCPToolFailure {
            // expected: in-band tool failure, not a JSON-RPC error
        } catch { XCTFail("expected MCPToolFailure, got \(error)") }
    }

    func test_getFlowDetail_badID_isInvalidParams() async {
        do {
            _ = try await makeExecutor().call(name: "get_flow_detail", arguments: ["id": "not-a-uuid"])
            XCTFail("expected invalidParams")
        } catch let error as MCPError {
            guard case .invalidParams = error else { return XCTFail("wrong error: \(error)") }
        } catch { XCTFail("wrong error type: \(error)") }
    }

    // MARK: Write tools forward to the engine

    func test_replayFlow_forwardsAndRendersFailureInBand() async throws {
        let engine = StubEngine()
        engine.replayError = ProxyControlError.replayFailed("boom")
        do {
            _ = try await makeExecutor(engine).call(name: "replay_flow", arguments: ["id": UUID().uuidString])
            XCTFail("expected tool failure")
        } catch let failure as MCPToolFailure {
            XCTAssertTrue(failure.message.contains("boom"))
        }
        XCTAssertNotNil(engine.lastReplay)
    }

    func test_setSSLScope_mergesAndForwards() async throws {
        let engine = StubEngine()
        _ = try await makeExecutor(engine).call(name: "set_ssl_scope", arguments: [
            "enabled": true, "include": ["*.example.com"],
        ])
        XCTAssertEqual(engine.lastSSLScope?.enabled, true)
        XCTAssertEqual(engine.lastSSLScope?.include, ["*.example.com"])
    }

    func test_createRule_strictParse_missingMatch_isInvalidParams() async {
        do {
            _ = try await makeExecutor().call(name: "create_rule", arguments: [
                "name": "r", "actions": ["block": true],
            ])
            XCTFail("expected invalidParams for missing match")
        } catch let error as MCPError {
            guard case .invalidParams = error else { return XCTFail("wrong error: \(error)") }
        } catch { XCTFail("wrong error type: \(error)") }
    }

    func test_createRule_valid_addsToEngine() async throws {
        let engine = StubEngine()
        let out = try json(try await makeExecutor(engine).call(name: "create_rule", arguments: [
            "name": "block home",
            "match": ["url_pattern": "https://api.example.com/home"],
            "actions": ["block": true],
        ]))
        XCTAssertEqual(out["name"] as? String, "block home")
        XCTAssertEqual(engine.addedRules.count, 1)
        XCTAssertEqual(engine.rules.rules.count, 1)
    }

    func test_deleteRule_unknownID_isToolFailure() async {
        do {
            _ = try await makeExecutor().call(name: "delete_rule", arguments: ["id": UUID().uuidString])
            XCTFail("expected failure")
        } catch is MCPToolFailure {
        } catch { XCTFail("expected MCPToolFailure, got \(error)") }
    }

    func test_setRulesEnabled_requiresBool() async {
        do {
            _ = try await makeExecutor().call(name: "set_rules_enabled", arguments: [:])
            XCTFail("expected invalidParams")
        } catch let error as MCPError {
            guard case .invalidParams = error else { return XCTFail("wrong error: \(error)") }
        } catch { XCTFail("wrong error type: \(error)") }
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
