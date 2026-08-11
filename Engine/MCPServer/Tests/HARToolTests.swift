import Testing
import Foundation
import LoomSharedModels
@testable import MCPServer

/// The two directions a capture crosses the machine boundary: `import_har` brings a
/// recorded exchange in so it can be replayed and diffed like live traffic, and
/// `export_har` with redaction lets one go out without the credentials in it. Both
/// have a failure mode that looks like success — a partial import that reads as
/// complete, an "redacted" file that still holds a token — which is what this suite
/// is about.
@MainActor
@Suite struct HARToolTests {
    private func makeExecutor(_ engine: StubEngine) -> MCPToolExecutor {
        MCPToolExecutor(engine: engine, appVersion: "9.9", protocolVersion: "2025-06-18")
    }

    private func json(_ string: String) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: Data(string.utf8)) as? [String: Any])
    }

    /// Written to the scratch directory, never the app-support tree.
    private func writeTemp(_ contents: String, name: String = "capture.har") throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("loom-har-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try Data(contents.utf8).write(to: url)
        return url
    }

    private let goodEntry = """
    {"startedDateTime":"2026-07-20T10:00:00.000Z","time":120,
     "request":{"method":"GET","url":"https://api.example.com/v1/orders","headers":[]},
     "response":{"status":200,"headers":[],"content":{"size":2,"mimeType":"application/json","text":"{}"}}}
    """

    private func har(_ entries: String) -> String {
        """
        {"log":{"version":"1.2","creator":{"name":"Test","version":"1"},"entries":[\(entries)]}}
        """
    }

    // MARK: - import_har

    @Test func importsFlowsIntoTheCapture_labelledAsImported() async throws {
        let engine = StubEngine()
        let url = try writeTemp(har(goodEntry), name: "colleague.har")

        let out = try await json(makeExecutor(engine).call(name: "import_har", arguments: ["path": url.path]))
        #expect(out["imported"] as? Int == 1)
        #expect(out["importedFrom"] as? String == "colleague.har", "defaults to the file name")
        #expect((out["ids"] as? [String])?.count == 1, "ids come back so the flows can be replayed/diffed")

        #expect(engine.importedFlows.count == 1)
        #expect(engine.importedFlows.first?.importedFrom == "colleague.har")

        // …and it reads back through the ordinary tools, marked as imported.
        let listed = try #require(
            try JSONSerialization.jsonObject(
                with: Data(try await makeExecutor(engine).call(name: "get_recent_flows", arguments: [:]).utf8)
            ) as? [[String: Any]]
        )
        #expect(listed.first?["importedFrom"] as? String == "colleague.har",
                "imported traffic must never be indistinguishable from captured traffic")
    }

    @Test func anExplicitLabelWins() async throws {
        let engine = StubEngine()
        let url = try writeTemp(har(goodEntry))
        let out = try await json(makeExecutor(engine).call(
            name: "import_har", arguments: ["path": url.path, "label": "ENG-4521 repro"]
        ))
        #expect(out["importedFrom"] as? String == "ENG-4521 repro")
    }

    @Test func aPartialImportReportsWhatItSkipped() async throws {
        let engine = StubEngine()
        let bad = """
        {"startedDateTime":"2026-07-20T10:00:00Z","request":{"url":"https://api.example.com/x","headers":[]},
         "response":{"status":200,"headers":[]}}
        """
        let url = try writeTemp(har("\(goodEntry),\(bad)"))

        let out = try await json(makeExecutor(engine).call(name: "import_har", arguments: ["path": url.path]))
        #expect(out["imported"] as? Int == 1)
        #expect(out["skipped"] as? Int == 1, "\"1 of 2\" must not read as \"all of them\"")
        #expect((out["skippedReasons"] as? [String])?.isEmpty == false)
    }

    @Test func aFileThatIsNotAHARFailsWithAReasonRatherThanImportingNothing() async throws {
        let engine = StubEngine()
        let notJSON = try writeTemp("hello, world")
        let notHAR = try writeTemp(#"{"entries":[]}"#, name: "wrong-shape.har")
        let executor = makeExecutor(engine)

        await #expect(throws: MCPToolFailure.self) {
            try await executor.call(name: "import_har", arguments: ["path": notJSON.path])
        }
        await #expect(throws: MCPToolFailure.self) {
            try await executor.call(name: "import_har", arguments: ["path": notHAR.path])
        }
        await #expect(throws: MCPToolFailure.self) {
            try await executor.call(name: "import_har", arguments: ["path": "/nope/missing.har"])
        }
        await #expect(throws: MCPError.self) {
            try await executor.call(name: "import_har", arguments: [:])
        }
        #expect(engine.importedFlows.isEmpty)
    }

    @Test func anEmptyHARIsAFailure_notASilentSuccess() async throws {
        let engine = StubEngine()
        let url = try writeTemp(har(""))
        await #expect(throws: MCPToolFailure.self) {
            try await makeExecutor(engine).call(name: "import_har", arguments: ["path": url.path])
        }
    }

    @Test func importingIsAnAuditedWriteAction() async throws {
        let engine = StubEngine()
        let url = try writeTemp(har(goodEntry))
        _ = try await makeExecutor(engine).call(name: "import_har", arguments: ["path": url.path])
        #expect(engine.recordedAudits.map(\.tool) == ["import_har"])
        #expect(MCPToolExecutor.writeTools.contains("import_har"))
    }

    // MARK: - export_har redaction arguments

    @Test func redactionIsOptIn() throws {
        #expect(try MCPToolExecutor.redaction(from: .forTool("export_har", [:])) == nil, "a debugging export usually needs the token")
        #expect(try MCPToolExecutor.redaction(from: .forTool("export_har", ["redact": false])) == nil)
        #expect(try MCPToolExecutor.redaction(from: .forTool("export_har", ["redact": true])) != nil)
        // Asking for either detail implies redaction — no way to name headers and get
        // an unredacted file.
        #expect(try MCPToolExecutor.redaction(from: .forTool("export_har", ["redact_bodies": true]))?.dropBodies == true)
        let extra = try MCPToolExecutor.redaction(from: .forTool("export_har", ["redact_headers": ["x-internal"]]))
        #expect(extra?.headerNames.contains("x-internal") == true)
        #expect(extra?.headerNames.contains("authorization") == true, "the built-ins stay")
    }

    /// The dangerous argument combination: it reads as "redact these", and resolving it
    /// as "redact nothing" would write credentials to a file the caller believes is
    /// scrubbed.
    @Test func redactFalseWithRedactionOptionsIsRejected() {
        #expect(throws: MCPError.self) {
            try MCPToolExecutor.redaction(from: .forTool("export_har", ["redact": false, "redact_bodies": true]))
        }
        #expect(throws: MCPError.self) {
            try MCPToolExecutor.redaction(from: .forTool("export_har", ["redact": false, "redact_headers": ["authorization"]]))
        }
        #expect(throws: MCPError.self) {
            try MCPToolExecutor.redaction(from: .forTool("export_har", ["redact_headers": ["  "]]))
        }
    }

    @Test func aRedactedExportWritesNoSecretsAndSaysWhatItScrubbed() async throws {
        let engine = StubEngine()
        engine.flows = [Flow(
            id: UUID(),
            request: CapturedRequest(
                method: "GET", url: "https://api.example.com/v1/orders?access_token=SUPERSECRET",
                headers: [HeaderPair(name: "Authorization", value: "Bearer TOPSECRET")]
            ),
            startedAt: Date(timeIntervalSince1970: 1_000),
            outcome: .completed(
                CapturedResponse(statusCode: 200, headers: [], body: Data("PAYLOAD".utf8)),
                at: Date(timeIntervalSince1970: 1_000.2)
            )
        )]

        let out = try await json(makeExecutor(engine).call(name: "export_har", arguments: [
            "redact": true, "redact_bodies": true, "filename": "redaction-test-\(UUID().uuidString).har",
        ]))
        let path = try #require(out["path"] as? String)
        defer { try? FileManager.default.removeItem(atPath: path) }

        let text = try #require(String(data: try Data(contentsOf: URL(fileURLWithPath: path)), encoding: .utf8))
        #expect(!text.contains("SUPERSECRET"))
        #expect(!text.contains("TOPSECRET"))
        #expect(!text.contains("PAYLOAD"))
        #expect(text.contains(FlowRedaction.placeholder))

        // The reply says what was scrubbed, so a human asked to attach the file knows
        // what it does and doesn't still contain.
        let redacted = try #require(out["redacted"] as? [String: Any])
        #expect(redacted["bodiesDropped"] as? Bool == true)
        #expect((redacted["headers"] as? [String])?.contains("authorization") == true)
    }

    @Test func anUnredactedExportSaysNothingAboutRedaction() async throws {
        let engine = StubEngine()
        engine.flows = [Flow(
            id: UUID(),
            request: CapturedRequest(method: "GET", url: "https://api.example.com/x", headers: []),
            startedAt: Date(timeIntervalSince1970: 1),
            outcome: .completed(CapturedResponse(statusCode: 200, headers: []), at: Date(timeIntervalSince1970: 1))
        )]
        let out = try await json(makeExecutor(engine).call(name: "export_har", arguments: [
            "filename": "plain-test-\(UUID().uuidString).har",
        ]))
        if let path = out["path"] as? String { try? FileManager.default.removeItem(atPath: path) }
        #expect(out["redacted"] == nil)
    }
}
