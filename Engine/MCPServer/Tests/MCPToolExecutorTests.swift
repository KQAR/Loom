import Testing
import Foundation
import LoomSharedModels
@testable import MCPServer

/// Behavior contract for `MCPToolExecutor`, pinned before the registry refactor:
/// every advertised tool is dispatchable, argument validation stays strict, and
/// the executor forwards writes to the engine and renders results as JSON.
@MainActor
@Suite struct MCPToolExecutorTests {
    // Split rather than defaulted: a default argument expression is evaluated in a
    // nonisolated context, so `= StubEngine()` can't construct a @MainActor stub.
    private func makeExecutor(_ engine: StubEngine) -> MCPToolExecutor {
        MCPToolExecutor(engine: engine, appVersion: "9.9", protocolVersion: "2025-06-18")
    }

    private func makeExecutor() -> MCPToolExecutor {
        makeExecutor(StubEngine())
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
        // The blocking tools would each sit here for their default wait; give them a
        // deadline instead of skipping them, so they stay covered by this guard.
        let arguments: [String: [String: Any]] = [
            "wait_for_flow": ["max_seconds": 0.05],
            "wait_for_pending": ["max_seconds": 0.05],
        ]
        for name in names {
            if name == "export_har" { continue } // writes a real file to the app-support dir
            do {
                _ = try await executor.call(name: name, arguments: arguments[name] ?? [:])
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

    // MARK: Flow filtering — the arguments an agent uses to narrow a capture.

    @Test func getRecentFlows_includesStartedAt() async throws {
        let engine = StubEngine()
        engine.flows = [Fixtures.completedFlow(url: "https://a/1")]
        let out = try jsonArray(try await makeExecutor(engine).call(name: "get_recent_flows", arguments: [:]))
        // 1970-01-01T00:16:40Z — the fixture's startedAt.
        #expect(out.first?["startedAt"] as? String == "1970-01-01T00:16:40Z")
    }

    @Test func flowQuery_parsesEveryFilter() throws {
        let query = try MCPToolExecutor.flowQuery(from: [
            "host": "*.example.com",
            "method": ["post", "put"],
            "url_contains": "/orders",
            "status_min": 400,
            "status_max": 499,
            "only_errors": true,
            "device_ip": "192.168.1.9",
            "source_app": "com.apple.Safari",
        ])
        #expect(query.host == "*.example.com")
        #expect(query.methods == ["post", "put"])
        #expect(query.urlContains == "/orders")
        #expect(query.statusMin == 400)
        #expect(query.statusMax == 499)
        #expect(query.onlyErrors)
        #expect(query.deviceIP == "192.168.1.9")
        #expect(query.sourceApp == "com.apple.Safari")
    }

    @Test func flowQuery_methodAcceptsASingleString() throws {
        #expect(try MCPToolExecutor.flowQuery(from: ["method": "get"]).methods == ["get"])
    }

    @Test func flowQuery_statusAcceptsExactOrClass() throws {
        let exact = try MCPToolExecutor.flowQuery(from: ["status": 503])
        #expect(exact.statusMin == 503 && exact.statusMax == 503)
        let klass = try MCPToolExecutor.flowQuery(from: ["status": "5xx"])
        #expect(klass.statusMin == 500 && klass.statusMax == 599)
        let upper = try MCPToolExecutor.flowQuery(from: ["status": "4XX"])
        #expect(upper.statusMin == 400 && upper.statusMax == 499)
    }

    @Test func flowQuery_sinceSecondsAndISO8601() throws {
        let relative = try #require(MCPToolExecutor.flowQuery(from: ["since_seconds": 60]).since)
        #expect(abs(relative.timeIntervalSinceNow + 60) < 5)

        let absolute = try #require(MCPToolExecutor.flowQuery(from: ["since": "2026-07-25T10:00:00Z"]).since)
        #expect(absolute == Date(timeIntervalSince1970: 1_784_973_600))
        // Fractional seconds are what JS clients emit — must parse, not throw.
        #expect(try MCPToolExecutor.flowQuery(from: ["since": "2026-07-25T10:00:00.123Z"]).since != nil)
    }

    /// A filter that silently fails to apply is worse than an error: the agent
    /// receives unfiltered traffic and believes it is filtered.
    @Test func flowQuery_malformedArguments_areRejected() {
        #expect(throws: MCPError.self) { try MCPToolExecutor.flowQuery(from: ["status": "abc"]) }
        #expect(throws: MCPError.self) { try MCPToolExecutor.flowQuery(from: ["status": true]) }
        #expect(throws: MCPError.self) { try MCPToolExecutor.flowQuery(from: ["method": 7]) }
        #expect(throws: MCPError.self) { try MCPToolExecutor.flowQuery(from: ["since": "yesterday"]) }
    }

    @Test func getRecentFlows_appliesTheFilter() async throws {
        let engine = StubEngine()
        engine.flows = [
            Fixtures.completedFlow(url: "https://api.example.com/orders"),
            Fixtures.completedFlow(url: "https://cdn.example.com/logo.png"),
        ]
        let out = try jsonArray(try await makeExecutor(engine).call(
            name: "get_recent_flows", arguments: ["host": "api.example.com"]
        ))
        #expect(out.count == 1)
        #expect(out.first?["url"] as? String == "https://api.example.com/orders")
    }

    // MARK: Capture control — pause/resume and discard, the isolation primitives.

    @Test func setRecording_forwardsToEngine() async throws {
        let engine = StubEngine()
        let executor = makeExecutor(engine)
        let out = try json(try await executor.call(name: "set_recording", arguments: ["recording": false]))
        #expect(out["isRecording"] as? Bool == false)
        #expect(engine.recording == false)
        _ = try await executor.call(name: "set_recording", arguments: ["recording": true])
        #expect(engine.recording)
    }

    @Test func setRecording_requiresABool() async {
        await #expect(throws: MCPError.self) {
            _ = try await makeExecutor().call(name: "set_recording", arguments: ["recording": "yes"])
        }
        await #expect(throws: MCPError.self) {
            _ = try await makeExecutor().call(name: "set_recording", arguments: [:])
        }
    }

    @Test func clearFlows_clearsAndReportsTheCount() async throws {
        let engine = StubEngine()
        engine.flows = [Fixtures.completedFlow(url: "https://a/1"), Fixtures.completedFlow(url: "https://a/2")]
        engine.proxyStatus = ProxyStatus(isRunning: true, port: 9090, capturedCount: 2)
        let out = try json(try await makeExecutor(engine).call(name: "clear_flows", arguments: [:]))
        #expect(out["cleared"] as? Int == 2)
        #expect(engine.clearFlowsCallCount == 1)
        #expect(engine.flows.isEmpty)
    }

    /// Both are destructive-ish writes, so both must land in the audit trail — the
    /// human's only record of what the agent did.
    @Test func captureControlTools_areAudited() async throws {
        let engine = StubEngine()
        let executor = makeExecutor(engine)
        _ = try await executor.call(name: "clear_flows", arguments: [:])
        _ = try await executor.call(name: "set_recording", arguments: ["recording": false])
        #expect(engine.recordedAudits.map(\.tool) == ["clear_flows", "set_recording"])
        #expect(MCPToolExecutor.writeTools.contains("clear_flows"))
        #expect(MCPToolExecutor.writeTools.contains("set_recording"))
    }

    @Test func getFlowDetail_includesHTTPVersion() async throws {
        let engine = StubEngine()
        let flow = Fixtures.completedFlow(url: "https://a/1", httpVersion: "HTTP/2")
        engine.flows = [flow]
        let out = try json(try await makeExecutor(engine).call(name: "get_flow_detail", arguments: ["id": flow.id.uuidString]))
        let response = try #require(out["response"] as? [String: Any])
        #expect(response["httpVersion"] as? String == "HTTP/2")
    }

    // MARK: Bounded, typed bodies — an agent must never be handed an unbounded
    // body, nor a `""` that could mean either "empty" or "binary".

    @Test func getFlowDetail_smallTextBody_isPlainString() async throws {
        let engine = StubEngine()
        let flow = Fixtures.flow(responseBody: Data(#"{"ok":true}"#.utf8))
        engine.flows = [flow]
        let out = try json(try await makeExecutor(engine).call(name: "get_flow_detail", arguments: ["id": flow.id.uuidString]))
        let response = try #require(out["response"] as? [String: Any])
        #expect(response["body"] as? String == #"{"ok":true}"#)
    }

    @Test func getFlowDetail_largeBody_isTruncatedWithPagingOffset() async throws {
        let engine = StubEngine()
        let body = Data(String(repeating: "x", count: 50_000).utf8)
        let flow = Fixtures.flow(responseBody: body)
        engine.flows = [flow]
        let out = try json(try await makeExecutor(engine).call(
            name: "get_flow_detail", arguments: ["id": flow.id.uuidString, "max_bytes": 1_000]
        ))
        let rendered = try #require((out["response"] as? [String: Any])?["body"] as? [String: Any])
        #expect(rendered["truncated"] as? Bool == true)
        #expect(rendered["bytes"] as? Int == 50_000)
        #expect((rendered["preview"] as? String)?.count == 1_000)
        #expect(rendered["nextOffset"] as? Int == 1_000)
    }

    @Test func getFlowDetail_bodyOffset_pagesThroughTheBody() async throws {
        let engine = StubEngine()
        let text = (0 ..< 500).map { "line \($0)" }.joined(separator: "\n")
        let flow = Fixtures.flow(responseBody: Data(text.utf8))
        engine.flows = [flow]
        let executor = makeExecutor(engine)

        var assembled = ""
        var offset = 0
        while true {
            let out = try json(try await executor.call(
                name: "get_flow_detail",
                arguments: ["id": flow.id.uuidString, "max_bytes": 300, "body_offset": offset]
            ))
            let body = try #require((out["response"] as? [String: Any])?["body"])
            if let whole = body as? String { assembled += whole; break }
            let page = try #require(body as? [String: Any])
            assembled += try #require(page["preview"] as? String)
            guard let next = page["nextOffset"] as? Int else { break }
            offset = next
        }
        #expect(assembled == text, "paging must reassemble the exact body")
    }

    @Test func getFlowDetail_multiByteBody_isNotCutMidCodePoint() async throws {
        let engine = StubEngine()
        // Every character is 3 bytes, so a 100-byte window lands mid-code-point.
        let text = String(repeating: "配置", count: 200)
        let flow = Fixtures.flow(responseBody: Data(text.utf8))
        engine.flows = [flow]
        let out = try json(try await makeExecutor(engine).call(
            name: "get_flow_detail", arguments: ["id": flow.id.uuidString, "max_bytes": 100]
        ))
        let rendered = try #require((out["response"] as? [String: Any])?["body"] as? [String: Any])
        let preview = try #require(rendered["preview"] as? String)
        #expect(!preview.contains("\u{FFFD}"), "must trim the partial code point, not emit U+FFFD")
        #expect(text.hasPrefix(preview))
    }

    @Test func getFlowDetail_binaryBody_isLabelled_notEmptyString() async throws {
        let engine = StubEngine()
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0xFF, 0xD8, 0xFE])
        let flow = Fixtures.flow(responseBody: png)
        engine.flows = [flow]
        let out = try json(try await makeExecutor(engine).call(name: "get_flow_detail", arguments: ["id": flow.id.uuidString]))
        let rendered = try #require((out["response"] as? [String: Any])?["body"] as? [String: Any])
        #expect(rendered["binary"] as? Bool == true)
        #expect(rendered["bytes"] as? Int == png.count)
    }

    @Test func getFlowDetail_emptyBody_staysEmptyString() async throws {
        let engine = StubEngine()
        let flow = Fixtures.flow(responseBody: nil)
        engine.flows = [flow]
        let out = try json(try await makeExecutor(engine).call(name: "get_flow_detail", arguments: ["id": flow.id.uuidString]))
        #expect((out["response"] as? [String: Any])?["body"] as? String == "")
    }

    @Test func getFlowDetail_webSocketFrames_areCappedAndFlagged() async throws {
        let engine = StubEngine()
        let messages = (0 ..< 250).map { index in
            WebSocketMessage(
                direction: .clientToServer, kind: .text,
                payload: Data("frame \(index)".utf8), timestamp: Date(timeIntervalSince1970: 1_000)
            )
        }
        var flow = Fixtures.flow(responseBody: nil)
        flow.webSocketMessages = messages
        engine.flows = [flow]
        let out = try json(try await makeExecutor(engine).call(
            name: "get_flow_detail", arguments: ["id": flow.id.uuidString, "ws_limit": 10]
        ))
        let ws = try #require(out["webSocket"] as? [String: Any])
        #expect(ws["messageCount"] as? Int == 250)
        #expect(ws["messagesTruncated"] as? Bool == true)
        let shown = try #require(ws["messages"] as? [[String: Any]])
        #expect(shown.count == 10)
        #expect(shown.last?["text"] as? String == "frame 249", "keeps the most recent frames")
    }

    /// Capture truncation is a *different* fact from render truncation: no
    /// `body_offset` can reach bytes that were never recorded. Both must be
    /// distinguishable, and the summary must flag it before an agent fetches detail.
    @Test func getFlowDetail_captureTruncatedBody_reportsWireSize() async throws {
        let engine = StubEngine()
        var flow = Fixtures.flow(responseBody: Data(repeating: 0x41, count: 100))
        flow.outcome = .completed(
            CapturedResponse(
                statusCode: 200, httpVersion: "HTTP/1.1", headers: [],
                body: Data(repeating: 0x41, count: 100), fullBodyBytes: 9_000_000
            ),
            at: Date(timeIntervalSince1970: 1_000.1)
        )
        engine.flows = [flow]
        let out = try json(try await makeExecutor(engine).call(name: "get_flow_detail", arguments: ["id": flow.id.uuidString]))
        let response = try #require(out["response"] as? [String: Any])
        #expect(response["bodyCaptureTruncated"] as? Bool == true)
        #expect(response["bodyBytesOnWire"] as? Int == 9_000_000)
        #expect(out["captureTruncated"] as? Bool == true)
    }

    @Test func getRecentFlows_flagCaptureTruncation() async throws {
        let engine = StubEngine()
        var truncated = Fixtures.flow(responseBody: Data("x".utf8))
        truncated.request.fullBodyBytes = 500_000
        engine.flows = [truncated, Fixtures.flow(responseBody: Data("y".utf8))]
        let out = try jsonArray(try await makeExecutor(engine).call(name: "get_recent_flows", arguments: [:]))
        #expect(out.first?["captureTruncated"] as? Bool == true)
        #expect(out.last?["captureTruncated"] == nil, "a complete capture carries no flag")
    }

    @Test func getFlowDetail_droppedWebSocketFrames_areReported() async throws {
        let engine = StubEngine()
        var flow = Fixtures.flow(responseBody: nil)
        flow.webSocketMessages = [
            WebSocketMessage(direction: .clientToServer, kind: .text, payload: Data("hi".utf8), timestamp: Date(timeIntervalSince1970: 1)),
        ]
        flow.webSocketDroppedMessages = 42
        engine.flows = [flow]
        let out = try json(try await makeExecutor(engine).call(name: "get_flow_detail", arguments: ["id": flow.id.uuidString]))
        let ws = try #require(out["webSocket"] as? [String: Any])
        #expect(ws["framesNotRecorded"] as? Int == 42)
        #expect(out["captureTruncated"] as? Bool == true)
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
    /// A completed flow carrying an arbitrary response body — for the body
    /// rendering (bounding / typing / paging) tests.
    static func flow(responseBody: Data?) -> Flow {
        Flow(
            id: UUID(),
            request: CapturedRequest(method: "GET", url: "https://a/body", headers: []),
            startedAt: Date(timeIntervalSince1970: 1_000),
            outcome: .completed(
                CapturedResponse(statusCode: 200, httpVersion: "HTTP/1.1", headers: [], body: responseBody),
                at: Date(timeIntervalSince1970: 1_000.1)
            )
        )
    }

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
