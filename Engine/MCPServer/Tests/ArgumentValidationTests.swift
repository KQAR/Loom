import Testing
import Foundation
import LoomSharedModels
@testable import MCPServer

/// An argument the schema doesn't declare must fail the call, not be dropped.
///
/// The bug these pin: `get_recent_flows` with `urlContains` (camel-cased
/// `url_contains`) returned the whole unfiltered ring. Every flow came back, which
/// reads like "the filter matched all of these" — an agent has no way to tell that
/// answer apart from a real one, so it reasons from the wrong set. Silence is the
/// defect; the filter being ignored is only how it happens.
@MainActor
@Suite struct ArgumentValidationTests {
    private func makeExecutor() -> MCPToolExecutor {
        MCPToolExecutor(engine: StubEngine(), appVersion: "9.9", protocolVersion: "2025-06-18")
    }

    private func message(_ error: any Error) -> String {
        guard let mcp = error as? MCPError else { return "\(error)" }
        return mcp.message
    }

    // MARK: The reported bug

    @Test func camelCasedFilter_isRejectedRatherThanIgnored() async {
        let executor = makeExecutor()
        await #expect(throws: MCPError.self) {
            _ = try await executor.call(name: "get_recent_flows", arguments: ["urlContains": "m=PROBE"])
        }
    }

    @Test func rejection_namesTheIntendedArgument() async throws {
        let executor = makeExecutor()
        let error = await #expect(throws: MCPError.self) {
            _ = try await executor.call(name: "get_recent_flows", arguments: ["urlContains": "m=PROBE"])
        }
        let text = message(try #require(error))
        #expect(text.contains("urlContains"))
        // The whole point of the suggestion: the caller learns the real key from the
        // error instead of diffing the schema by hand.
        #expect(text.contains("did you mean \"url_contains\""))
    }

    @Test func aDeclaredFilter_stillWorks() async throws {
        let executor = makeExecutor()
        _ = try await executor.call(name: "get_recent_flows", arguments: ["url_contains": "m=PROBE"])
    }

    // MARK: Where a typo is hardest to notice

    @Test func unknownKeyInsideANestedObject_isRejected() async throws {
        let executor = makeExecutor()
        let error = await #expect(throws: MCPError.self) {
            _ = try await executor.call(name: "set_rule", arguments: [
                "name": "mock",
                "match": ["url_pattern": "https://api.example.com/*"],
                "actions": ["rewrite_request": ["setHeaders": ["x-env": "staging"]]],
            ])
        }
        let text = message(try #require(error))
        // Path, so a deeply buried key is locatable without guessing which level.
        #expect(text.contains("actions.rewrite_request.setHeaders"))
        #expect(text.contains("did you mean \"set_headers\""))
    }

    @Test func unknownKeyInsideAnArrayElement_isRejectedWithItsIndex() async throws {
        let executor = makeExecutor()
        let error = await #expect(throws: MCPError.self) {
            _ = try await executor.call(name: "set_rule", arguments: [
                "name": "substitute",
                "match": ["url_pattern": "https://api.example.com/*"],
                "actions": ["response_substitutions": [
                    ["field": "body", "match": "staging", "replacement": "prod"],
                    ["field": "body", "match": "a", "caseSensitive": true],
                ]],
            ])
        }
        let text = message(try #require(error))
        #expect(text.contains("response_substitutions[1].caseSensitive"))
        #expect(text.contains("did you mean \"case_sensitive\""))
    }

    // MARK: What must keep passing

    @Test func freeFormMaps_acceptAnyKey() async throws {
        let executor = makeExecutor()
        // `set_headers` is a header map — its keys are data, not schema. Validating
        // them would reject every legitimate rule that sets a header.
        _ = try await executor.call(name: "set_rule", arguments: [
            "name": "mock",
            "match": ["url_pattern": "https://api.example.com/*"],
            "actions": ["rewrite_request": ["set_headers": ["x-anything-at-all": "1"]]],
        ])
    }

    @Test func underscoredKeys_pass() async throws {
        let executor = makeExecutor()
        // MCP reserves `_meta` on any object in the protocol; rejecting it here would
        // refuse spec-legal requests from a conforming client.
        _ = try await executor.call(name: "get_recent_flows", arguments: [
            "limit": 5, "_meta": ["progressToken": "abc"],
        ])
    }

    @Test func aToolWithNoArguments_saysSo() async throws {
        let executor = makeExecutor()
        let error = await #expect(throws: MCPError.self) {
            _ = try await executor.call(name: "get_proxy_status", arguments: ["verbose": true])
        }
        #expect(message(try #require(error)).contains("takes no arguments"))
    }

    // MARK: The suggestion must not invent a neighbour

    @Test func aGenuinelyUnknownKey_isNotMatchedToASimilarOne() async throws {
        let executor = makeExecutor()
        let error = await #expect(throws: MCPError.self) {
            _ = try await executor.call(name: "get_recent_flows", arguments: ["status_mid": 300])
        }
        let text = message(try #require(error))
        // `status_min` / `status_max` are one character away. Suggesting either would
        // send the caller to a filter that means something else, so only a
        // case/separator variant of a real key ever gets suggested.
        #expect(!text.contains("did you mean"))
        #expect(text.contains("status_min"), "the accepted list still shows what is legal")
    }

    // MARK: A refused call is not an audited call

    @Test func aRejectedWriteCall_isNotRecordedInTheAuditTrail() async throws {
        let engine = StubEngine()
        let executor = MCPToolExecutor(engine: engine, appVersion: "9.9", protocolVersion: "2025-06-18")
        _ = await #expect(throws: MCPError.self) {
            _ = try await executor.call(name: "set_rule", arguments: ["nombre": "mock"])
        }
        // Nothing reached real traffic, so the trail must not imply an attempt was
        // made — same treatment as an unknown tool name.
        #expect(engine.recordedAudits.isEmpty)
    }
}
