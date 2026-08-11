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
        // Built per call rather than looked up in a dictionary declared out here: this
        // suite is `@MainActor` and `call` is nonisolated, so a stored `[String: Any]`
        // would belong to the main-actor region and handing it over is what strict
        // concurrency rejects. A fresh literal is disconnected, which is the truth.
        func arguments(for name: String) -> sending [String: Any] {
            switch name {
            case "wait_for_flow", "wait_for_pending": ["max_seconds": 0.05]
            default: [:]
            }
        }
        for name in names {
            if name == "export_har" { continue } // writes a real file to the app-support dir
            do {
                _ = try await executor.call(name: name, arguments: arguments(for: name))
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

    /// "Advertised but undispatchable" is now impossible by construction — one
    /// `MCPTool` carries both — so what is left to check is the *index*: a duplicate
    /// name would silently drop one tool's handler while both stayed advertised.
    @Test func toolIndex_coversEveryToolExactlyOnce() {
        let names = MCPToolExecutor.tools.map(\.name)
        #expect(
            MCPToolExecutor.toolsByName.count == names.count,
            "duplicate tool name: \(names.count - MCPToolExecutor.toolsByName.count) tool(s) shadowed"
        )
        #expect(Set(names) == Set(MCPToolExecutor.toolsByName.keys))
        #expect(Set(names) == Set(makeExecutor().toolDefinitions.compactMap { $0["name"] as? String }))
    }

    /// The tool surface must not promise that disabling the system proxy restores
    /// whoever held it before. Loom deliberately does not (ROADMAP / AGENTS: an app
    /// that may have exited would break every request on the machine), and the
    /// runtime reply says so — but the *schema* went on claiming a restore for a
    /// release after the reply was fixed, and the schema is what an agent reads at
    /// `tools/list` and relays to the human. Prose is pinned here precisely because
    /// nothing else can: a description is the one part of a tool the compiler will
    /// never check.
    @Test func noToolDescription_promisesToRestoreThePreviousProxyOwner() {
        for definition in makeExecutor().toolDefinitions {
            let name = definition["name"] as? String ?? "?"
            for text in Self.descriptions(in: definition) {
                let lowered = text.lowercased()
                // "…never restores the previous…" is the correction, not the claim.
                guard lowered.contains("restore") else { continue }
                #expect(
                    !lowered.contains("restore the previous") && !lowered.contains("restores the previous"),
                    "\(name): a description promises to restore the previous proxy settings; Loom turns the proxy off instead"
                )
            }
        }
    }

    /// Every `description` string anywhere in a tool definition, including the ones
    /// nested inside its input schema's properties — where the drift above lived.
    private static func descriptions(in value: Any) -> [String] {
        switch value {
        case let dictionary as [String: Any]:
            var found: [String] = []
            for (key, nested) in dictionary {
                if key == "description", let text = nested as? String { found.append(text) }
                found.append(contentsOf: descriptions(in: nested))
            }
            return found
        case let array as [Any]:
            return array.flatMap { descriptions(in: $0) }
        default:
            return []
        }
    }

    /// `-32602`, not `-32601`: `tools/call` was found, its `name` parameter wasn't, and
    /// that is the code the spec assigns to "unknown tool". `-32601` would tell the
    /// client the *method* is missing and invite it to stop calling `tools/call` at all.
    @Test func unknownTool_throwsInvalidParams() async {
        do {
            _ = try await makeExecutor().call(name: "does_not_exist", arguments: [:])
            Issue.record("expected unknownTool")
        } catch let error as MCPError {
            guard case .unknownTool = error else { Issue.record("wrong error: \(error)"); return }
            #expect(error.code == -32_602)
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
        let query = try MCPToolExecutor.flowQuery(from: .forTool("get_recent_flows", [
            "host": "*.example.com",
            "method": ["post", "put"],
            "url_contains": "/orders",
            "header_contains": "authorization",
            "body_contains": "AB-9931",
            "status_min": 400,
            "status_max": 499,
            "only_errors": true,
            "device_ip": "192.168.1.9",
            "source_app": "com.apple.Safari",
        ]))
        #expect(query.host == "*.example.com")
        #expect(query.methods == ["post", "put"])
        #expect(query.urlContains == "/orders")
        #expect(query.headerContains == "authorization")
        #expect(query.bodyContains == "AB-9931")
        #expect(query.statusMin == 400)
        #expect(query.statusMax == 499)
        #expect(query.onlyErrors)
        #expect(query.deviceIP == "192.168.1.9")
        #expect(query.sourceApp == "com.apple.Safari")
    }

    @Test func flowQuery_methodAcceptsASingleString() throws {
        #expect(try MCPToolExecutor.flowQuery(from: .forTool("get_recent_flows", ["method": "get"])).methods == ["get"])
    }

    @Test func flowQuery_statusAcceptsExactOrClass() throws {
        let exact = try MCPToolExecutor.flowQuery(from: .forTool("get_recent_flows", ["status": 503]))
        #expect(exact.statusMin == 503 && exact.statusMax == 503)
        let klass = try MCPToolExecutor.flowQuery(from: .forTool("get_recent_flows", ["status": "5xx"]))
        #expect(klass.statusMin == 500 && klass.statusMax == 599)
        let upper = try MCPToolExecutor.flowQuery(from: .forTool("get_recent_flows", ["status": "4XX"]))
        #expect(upper.statusMin == 400 && upper.statusMax == 499)
    }

    @Test func flowQuery_sinceSecondsAndISO8601() throws {
        let relative = try #require(MCPToolExecutor.flowQuery(from: .forTool("get_recent_flows", ["since_seconds": 60])).since)
        #expect(abs(relative.timeIntervalSinceNow + 60) < 5)

        let absolute = try #require(MCPToolExecutor.flowQuery(from: .forTool("get_recent_flows", ["since": "2026-07-25T10:00:00Z"])).since)
        #expect(absolute == Date(timeIntervalSince1970: 1_784_973_600))
        // Fractional seconds are what JS clients emit — must parse, not throw.
        #expect(try MCPToolExecutor.flowQuery(from: .forTool("get_recent_flows", ["since": "2026-07-25T10:00:00.123Z"])).since != nil)
    }

    /// A filter that silently fails to apply is worse than an error: the agent
    /// receives unfiltered traffic and believes it is filtered.
    @Test func flowQuery_malformedArguments_areRejected() {
        #expect(throws: MCPError.self) { try MCPToolExecutor.flowQuery(from: .forTool("get_recent_flows", ["status": "abc"])) }
        #expect(throws: MCPError.self) { try MCPToolExecutor.flowQuery(from: .forTool("get_recent_flows", ["status": true])) }
        #expect(throws: MCPError.self) { try MCPToolExecutor.flowQuery(from: .forTool("get_recent_flows", ["method": 7])) }
        #expect(throws: MCPError.self) { try MCPToolExecutor.flowQuery(from: .forTool("get_recent_flows", ["since": "yesterday"])) }
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

    /// The write reply has to say whether the rule will actually do anything.
    ///
    /// Found by driving the tools: `set_rule` returned a clean echo — including the
    /// rule's own `"enabled": true`, which reads as confirmation — while the master
    /// switch was off, so the mock never fired. No error, no warning, and the only
    /// way to notice was to independently call `list_rules` and read a field nothing
    /// pointed at. The agent had already told the human the endpoint was mocked.
    @Test func setRule_saysWhenTheMasterSwitchWillStopItFromApplying() async throws {
        let engine = StubEngine()
        engine.rules.enabled = false
        let out = try json(try await makeExecutor(engine).call(name: "set_rule", arguments: [
            "name": "mock order 500",
            "match": ["url_pattern": "*/api/order/*"],
            "actions": ["mock_response": ["status_code": 500]],
        ]))
        #expect(out["effective"] as? Bool == false)
        let reason = try #require(out["ineffectiveReason"] as? String)
        #expect(reason.contains("set_rules_enabled"), "the reason must name the fix: \(reason)")
    }

    @Test func setRule_reportsEffectiveWhenTheRuleWillApply() async throws {
        let engine = StubEngine()   // master switch on by default
        let out = try json(try await makeExecutor(engine).call(name: "set_rule", arguments: [
            "name": "mock order 500",
            "match": ["url_pattern": "*/api/order/*"],
            "actions": ["mock_response": ["status_code": 500]],
        ]))
        // Always present, so a missing key can't be read as "fine".
        #expect(out["effective"] as? Bool == true)
        #expect(out["ineffectiveReason"] == nil)
    }

    @Test func setRule_saysWhenTheRuleItselfIsDisabled() async throws {
        let engine = StubEngine()
        let out = try json(try await makeExecutor(engine).call(name: "set_rule", arguments: [
            "name": "parked", "enabled": false,
            "match": ["url_pattern": "*/api/order/*"],
            "actions": ["block": true],
        ]))
        #expect(out["effective"] as? Bool == false)
        #expect((out["ineffectiveReason"] as? String)?.contains("disabled") == true)
    }

    /// Same silent no-op, reached the other way: enabling a group changes nothing
    /// observable while the master switch is off.
    @Test func setGroupEnabled_saysWhenTheMasterSwitchWillStopItFromApplying() async throws {
        let engine = StubEngine()
        engine.rules.enabled = false
        engine.rules.rules = [TrafficRule(
            name: "member", group: "failure-mode",
            match: RuleMatch(urlPattern: "https://a/*"), actions: RuleActions(route: .block)
        )]
        let out = try json(try await makeExecutor(engine).call(name: "set_group_enabled", arguments: [
            "group": "failure-mode", "enabled": true,
        ]))
        #expect(out["effective"] as? Bool == false)
        #expect((out["ineffectiveReason"] as? String)?.contains("set_rules_enabled") == true)
    }

    /// The third switch. A rule can be `enabled: true` and still inert because its
    /// group is switched off — invisible on the rule itself, so `effective` has to
    /// name it or the agent reports a mock that never fires.
    @Test func setRule_saysWhenItsGroupIsSwitchedOff() async throws {
        let engine = StubEngine()
        engine.rules.disabledGroups = ["scenario-a"]
        let out = try json(try await makeExecutor(engine).call(name: "set_rule", arguments: [
            "name": "in a parked group", "group": "scenario-a",
            "match": ["url_pattern": "https://a/*"], "actions": ["block": true],
        ]))
        #expect(out["enabled"] as? Bool == true, "the rule's own switch really is on")
        #expect(out["effective"] as? Bool == false)
        #expect((out["ineffectiveReason"] as? String)?.contains("set_group_enabled") == true)
    }

    /// `list_rules` is where the human-invisible fact has to show up too: a group
    /// switch lives on the state, not on any rule in it.
    @Test func listRules_reportsSwitchedOffGroups() async throws {
        let engine = StubEngine()
        engine.rules.rules = [TrafficRule(
            name: "member", group: "scenario-a",
            match: RuleMatch(urlPattern: "https://a/*"), actions: RuleActions(route: .block)
        )]
        let executor = makeExecutor(engine)
        let quiet = try json(try await executor.call(name: "list_rules", arguments: [:]))
        #expect(quiet["disabledGroups"] == nil, "nothing switched off, nothing to say")

        _ = try await executor.call(name: "set_group_enabled", arguments: ["group": "scenario-a", "enabled": false])
        let out = try json(try await executor.call(name: "list_rules", arguments: [:]))
        #expect(out["disabledGroups"] as? [String] == ["scenario-a"])
    }

    /// A group switch is not a batch write, so "how many rules did this affect" and
    /// "how many now apply" are different numbers, and the reply carries both.
    @Test func setGroupEnabled_reportsMembersAndHowManyApply() async throws {
        let engine = StubEngine()
        engine.rules.rules = [
            TrafficRule(name: "on", group: "g", match: RuleMatch(urlPattern: "https://a/*"), actions: RuleActions(route: .block)),
            TrafficRule(name: "off by hand", group: "g", isEnabled: false,
                        match: RuleMatch(urlPattern: "https://b/*"), actions: RuleActions(route: .block)),
        ]
        let executor = makeExecutor(engine)
        _ = try await executor.call(name: "set_group_enabled", arguments: ["group": "g", "enabled": false])
        let out = try json(try await executor.call(name: "set_group_enabled", arguments: ["group": "g", "enabled": true]))
        #expect(out["members"] as? Int == 2)
        #expect(out["active"] as? Int == 1, "the hand-disabled member is not switched back on")
        #expect(out["effective"] as? Bool == true)
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

    /// `isWrite` decides auditing; the "This is a write action." marker is what
    /// tells the *agent*. Those are two different readers of the same fact, so they
    /// still have to be checked against each other — the flag can't be derived from
    /// the prose (a typo would switch auditing off) and the prose can't be derived
    /// from the flag (it's a sentence, not a label).
    @Test func writeFlag_agreesWithTheAdvertisedMarker() {
        // Match without the trailing period: some markers read "This is a write
        // action (writes a file)." rather than "…action.".
        let marked = Set(MCPToolExecutor.tools
            .filter { $0.description.contains("This is a write action") }
            .map(\.name))
        let flagged = Set(MCPToolExecutor.tools.filter(\.isWrite).map(\.name))
        #expect(marked == flagged,
                "a write tool must say so to the agent and be audited; diff: \(marked.symmetricDifference(flagged))")
        #expect(flagged == MCPToolExecutor.writeTools)
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
