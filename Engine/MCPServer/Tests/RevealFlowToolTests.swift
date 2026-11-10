import Foundation
import LoomSharedModels
import Testing
@testable import MCPServer

/// `reveal_flow` moves the human's selection, so the two things that must hold are
/// honesty (an unknown id, or a row the window can't show, is an error — never a
/// success the agent relays as "look at it") and accountability (it is audited).
@MainActor
@Suite struct RevealFlowToolTests {
    private let flow = Flow(
        request: CapturedRequest(method: "GET", url: "https://a.test/x", headers: []),
        startedAt: Date(timeIntervalSince1970: 0)
    )

    private func executor(
        _ engine: StubEngine, reveal: (@Sendable (Flow.ID) async -> FlowRevealOutcome)?
    ) -> MCPToolExecutor {
        var executor = MCPToolExecutor(engine: engine, appVersion: "9.9", protocolVersion: "2025-06-18")
        executor.reveal = reveal
        return executor
    }

    @Test func revealsAndReportsWhatWasCleared() async throws {
        let engine = StubEngine()
        engine.flows = [flow]
        let id = flow.id
        let out = try await executor(engine) { asked in
            #expect(asked == id)
            return FlowRevealOutcome(shown: true, cleared: [.sidebarSelection, .findBar])
        }.call(name: "reveal_flow", arguments: ["id": id.uuidString])
        let json = try #require(try JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any])
        #expect(json["shown"] as? Bool == true)
        #expect(json["cleared"] as? [String] == ["sidebar_selection", "find_bar"])
        #expect(engine.recordedAudits.last?.tool == "reveal_flow")
        #expect(engine.recordedAudits.last?.succeeded == true)
    }

    @Test func anUnknownIdIsAnError_andTheWindowIsNotAsked() async {
        await #expect(throws: (any Error).self) {
            try await executor(StubEngine()) { _ in
                Issue.record("the window must not be asked about a flow that doesn't exist")
                return FlowRevealOutcome(shown: true)
            }.call(name: "reveal_flow", arguments: ["id": UUID().uuidString])
        }
    }

    @Test func aRowTheWindowCannotShowIsAnError() async {
        let engine = StubEngine()
        engine.flows = [flow]
        await #expect(throws: (any Error).self) {
            try await executor(engine) { _ in FlowRevealOutcome(shown: false, reason: "too old") }
                .call(name: "reveal_flow", arguments: ["id": flow.id.uuidString])
        }
        #expect(engine.recordedAudits.last?.succeeded == false)
    }

    @Test func withoutAWindowItSaysSo() async {
        let engine = StubEngine()
        engine.flows = [flow]
        await #expect(throws: (any Error).self) {
            try await executor(engine, reveal: nil)
                .call(name: "reveal_flow", arguments: ["id": flow.id.uuidString])
        }
    }
}
