import ComposableArchitecture
import Foundation
import LoomSharedModels
import Testing
@testable import AppFeature

/// The audit window's boot seed is history: one action, applied once, and not a
/// write that just happened.
///
/// It used to replay the stored trail as up to 500 `entryReceived` actions, each a
/// reducer run, an observed-array write and a `mirroredStateWriteRecorded` delegate —
/// so launch asked the parent to re-read every mirror for writes made in earlier
/// sessions.
@MainActor
@Suite struct AuditHistorySeedTests {
    private func entry(_ tool: String) -> AuditEntry {
        AuditEntry(tool: tool, source: .mcp, succeeded: true, arguments: "{}", detail: "ok")
    }

    @Test func historyLandsInOneActionAndReReadsNothing() async {
        let history = [entry("set_rule"), entry("set_ssl_scope"), entry("resume")]
        let store = TestStore(initialState: AuditFeature.State()) { AuditFeature() }
        await store.send(.historySeeded(history)) {
            $0.entries = IdentifiedArray(uniqueElements: history)
        }
        // No `.delegate(.mirroredStateWriteRecorded)` is received: TestStore would fail
        // on an unhandled one.
    }

    @Test func aReSeedDedupsAndKeepsTheBound() async {
        let first = entry("set_rule")
        var state = AuditFeature.State()
        state.entries = [first]
        let flood = (0 ..< AuditFeature.State.displayCap + 10).map { _ in entry("set_rule") }
        let store = TestStore(initialState: state) { AuditFeature() }
        store.exhaustivity = .off
        await store.send(.historySeeded([first] + flood))
        #expect(store.state.entries.count == AuditFeature.State.displayCap)
        #expect(store.state.entries.last?.id == flood.last?.id, "the newest are the ones kept")
    }
}
