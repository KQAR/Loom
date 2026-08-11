import Testing
import Foundation
import LoomSharedModels
@testable import MCPServer

/// The reading side of the tool surface: what a wrong-typed argument does, what the
/// two number spellings mean, and the two defects the typed reader was written to
/// close (a silently-ignored value, and a key a handler reads but no schema
/// advertises).
@MainActor
@Suite struct MCPArgumentsTests {
    private func makeExecutor(_ engine: StubEngine = StubEngine()) -> MCPToolExecutor {
        MCPToolExecutor(engine: engine, appVersion: "9.9", protocolVersion: "2025-06-18")
    }

    // MARK: A wrong type is an error, never an absent value

    @Test func aWrongTypedFilter_isRejectedRatherThanIgnored() async {
        // `only_errors: "true"` used to read as `false` through `as? Bool ?? false`,
        // so the agent got every flow back believing it had asked for failures only.
        await #expect(throws: MCPError.self) {
            try await makeExecutor().call(name: "get_recent_flows", arguments: ["only_errors": "true"])
        }
        await #expect(throws: MCPError.self) {
            try await makeExecutor().call(name: "get_recent_flows", arguments: ["host": 3])
        }
        await #expect(throws: MCPError.self) {
            try await makeExecutor().call(name: "set_recording", arguments: ["recording": "off"])
        }
    }

    @Test func aWrongTypedGroup_noLongerSilentlyUngroupsTheRule() async throws {
        let engine = StubEngine()
        await #expect(throws: MCPError.self) {
            try await makeExecutor(engine).call(name: "set_rule", arguments: [
                "name": "n", "group": 3, "match": ["url_pattern": "https://a/"], "actions": ["block": true],
            ])
        }
    }

    // MARK: One JSON number type, two spellings

    @Test func aWholeDoubleIsTheSameRequestAsAnInteger() throws {
        // What a JS/Python client's encoder may write. `as? Int` failed on it and the
        // caller silently got the default.
        #expect(try MCPArguments.forTool("get_recent_flows", ["limit": 5.0]).int("limit") == 5)
        #expect(try MCPArguments.forTool("wait_for_flow", ["max_seconds": 5]).double("max_seconds") == 5)
    }

    @Test func aFractionalValueIsRejectedRatherThanTruncated() {
        #expect(throws: MCPError.self) {
            try MCPArguments.forTool("get_recent_flows", ["limit": 2.5]).int("limit")
        }
    }

    @Test func aJSONBooleanIsNotAnInteger_andViceVersa() throws {
        // NSNumber conflates them; `JSONValue` keeps them apart, or `only_errors: 1`
        // would be `true` and `limit: true` would be 1.
        #expect(throws: MCPError.self) {
            try MCPArguments.forTool("get_recent_flows", ["only_errors": 1]).bool("only_errors")
        }
        #expect(throws: MCPError.self) {
            try MCPArguments.forTool("get_recent_flows", ["limit": true]).int("limit")
        }
    }

    @Test func aNullIsAnAbsentValue() throws {
        // A client that spells "no filter" as an explicit null must not get a type
        // error for it — JSON's null and an omitted key mean the same thing here.
        #expect(try MCPArguments.forTool("get_recent_flows", ["host": nil]).string("host") == nil)
        #expect(MCPArguments.forTool("get_recent_flows", ["host": nil]).has("host") == false)
    }

    // MARK: The alias that never worked

    @Test func resume_acceptsTheIdSpellingItsDescriptionPromises() async throws {
        // `resume` reads `id` as an alias for `pending_id` and says so in its
        // description — but the schema didn't declare it, so `validateArguments`
        // refused the call at the choke point before the handler ran. Nothing held,
        // so this reaches the engine and fails there; what must NOT come back is
        // "unknown argument id".
        let executor = makeExecutor()
        await #expect(throws: MCPToolFailure.self) {
            try await executor.call(name: "resume", arguments: ["id": UUID().uuidString])
        }
    }

    @Test func resume_stillRejectsAnUndeclaredKey() async {
        await #expect(throws: MCPError.self) {
            try await makeExecutor().call(
                name: "resume", arguments: ["pendingId": UUID().uuidString]
            )
        }
    }

    // MARK: Nested reads keep their path

    @Test func aNestedTypeErrorNamesItsPath() async throws {
        let engine = StubEngine()
        do {
            _ = try await makeExecutor(engine).call(name: "set_rule", arguments: [
                "name": "n",
                "match": ["url_pattern": "https://a/"],
                "actions": ["map_local": ["path": 7]],
            ])
            Issue.record("a wrong-typed nested argument must not be accepted")
        } catch let error as MCPError {
            #expect(
                error.message.contains("actions.map_local.path"),
                "the path is what tells the caller which of the nested objects to fix: \(error.message)"
            )
        }
    }

    // MARK: The audit trail still reads the arguments

    @Test func auditArgumentsRenderJSON_withSecretsRedacted() {
        let rendered = MCPToolExecutor.auditArguments([
            "host_pattern": "*.corp.example",
            "pkcs12_base64": "MIIKfQIBAzCC",
            "passphrase": "hunter2",
            "enabled": true,
            "count": 3,
        ])
        #expect(rendered.contains("\"host_pattern\":\"*.corp.example\""))
        #expect(rendered.contains("\"pkcs12_base64\":\"<redacted>\""))
        #expect(rendered.contains("\"passphrase\":\"<redacted>\""))
        #expect(!rendered.contains("hunter2"))
        // An integer stays an integer: the human reading the trail should see what the
        // agent sent, not a `3` re-rendered as `3.0`.
        #expect(rendered.contains("\"count\":3"))
        #expect(MCPToolExecutor.auditArguments([:]) == "{}")
    }
}
