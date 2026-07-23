import ComposableArchitecture
import SharedModels
import XCTest

@testable import AppFeature

/// `TestStore` coverage for the load-bearing reducer flows: the optimistic
/// rule writes + re-sync, the boot idempotency guard, and replay insertion.
/// These are the paths where a blind refactor (e.g. the planned RulesFeature
/// split) would silently regress.
@MainActor
final class AppFeatureReducerTests: XCTestCase {
    private struct StubError: LocalizedError {
        var errorDescription: String? { "save failed" }
    }

    // MARK: Boot idempotency

    func test_task_isNoOpOnceBooted() async {
        var initial = AppFeature.State()
        initial.didBoot = true // already booted; re-render must not restart the proxy
        let store = TestStore(initialState: initial) { AppFeature() }
        // No dependencies are overridden: if `.task` re-ran its effect it would
        // touch `proxyClient.start` (unimplemented) and fail the test.
        await store.send(.task)
    }

    // MARK: Rule save — new

    func test_ruleEditorSaved_new_optimisticAppend_flipsMasterSwitch_thenResyncs() async {
        let rule = Fixtures.rule(name: "Block home")
        var initial = AppFeature.State()
        initial.editingRule = rule
        initial.editingRuleIsNew = true
        initial.rulesState = RulesState(enabled: false, rules: [])
        initial.rulesMessage = "stale error"

        // The engine's authoritative state differs from the optimistic guess (it
        // annotated the rule); the re-sync must adopt engine truth over the guess.
        var synced = rule
        synced.comment = "persisted"
        let loaded = RulesState(enabled: true, rules: [synced])
        let store = TestStore(initialState: initial) {
            AppFeature()
        } withDependencies: {
            $0.proxyClient.setRulesEnabled = { _ in }
            $0.proxyClient.addRule = { _ in }
            $0.proxyClient.rulesState = { loaded }
        }

        await store.send(.ruleEditorSaved(rule, isNew: true)) {
            $0.editingRule = nil
            $0.rulesMessage = nil
            $0.rulesState.enabled = true          // saving a new rule makes the engine live
            $0.rulesState.rules = [rule]           // optimistic append before the re-sync
        }
        await store.receive(\.rulesStateLoaded) {
            $0.rulesState = loaded
        }
    }

    func test_ruleEditorSaved_new_addRuleThrows_surfacesMessage() async {
        let rule = Fixtures.rule()
        var initial = AppFeature.State()
        initial.editingRule = rule
        initial.editingRuleIsNew = true
        initial.rulesState = RulesState(enabled: false, rules: [])

        let loaded = RulesState(enabled: true, rules: []) // engine rejected the write
        let store = TestStore(initialState: initial) {
            AppFeature()
        } withDependencies: {
            $0.proxyClient.setRulesEnabled = { _ in }
            $0.proxyClient.addRule = { _ in throw StubError() }
            $0.proxyClient.rulesState = { loaded }
        }

        await store.send(.ruleEditorSaved(rule, isNew: true)) {
            $0.editingRule = nil
            $0.rulesMessage = nil
            $0.rulesState.enabled = true
            $0.rulesState.rules = [rule]
        }
        await store.receive(\.ruleWriteFailed) {
            $0.rulesMessage = "Couldn’t save rule: save failed"
        }
        await store.receive(\.rulesStateLoaded) {
            $0.rulesState = loaded // re-sync drops the optimistic rule the engine refused
        }
    }

    // MARK: Rule save — update

    func test_ruleEditorSaved_update_replacesInPlace_thenResyncs() async {
        let id = UUID()
        let original = Fixtures.rule(id: id, name: "Original")
        var edited = original
        edited.name = "Edited"

        var initial = AppFeature.State()
        initial.editingRule = edited
        initial.editingRuleIsNew = false
        initial.rulesState = RulesState(enabled: true, rules: [original])

        var synced = edited
        synced.comment = "persisted" // engine truth differs from the optimistic replace
        let loaded = RulesState(enabled: true, rules: [synced])
        let store = TestStore(initialState: initial) {
            AppFeature()
        } withDependencies: {
            $0.proxyClient.updateRule = { _ in }
            $0.proxyClient.rulesState = { loaded }
        }

        await store.send(.ruleEditorSaved(edited, isNew: false)) {
            $0.editingRule = nil
            $0.rulesMessage = nil
            $0.rulesState.rules = [edited]
        }
        await store.receive(\.rulesStateLoaded) {
            $0.rulesState = loaded
        }
    }

    // MARK: ruleWriteFailed

    func test_ruleWriteFailed_setsMessage() async {
        let store = TestStore(initialState: AppFeature.State()) { AppFeature() }
        await store.send(.ruleWriteFailed("boom")) {
            $0.rulesMessage = "boom"
        }
    }

    // MARK: Master switch

    func test_toggleRulesTapped_optimisticFlip_thenResyncs() async {
        var initial = AppFeature.State()
        initial.rulesState = RulesState(enabled: false, rules: [])
        // Engine returns the rules it actually holds — distinct from the empty
        // optimistic state, so the re-sync is observable.
        let loaded = RulesState(enabled: true, rules: [Fixtures.rule()])
        let store = TestStore(initialState: initial) {
            AppFeature()
        } withDependencies: {
            $0.proxyClient.setRulesEnabled = { _ in }
            $0.proxyClient.rulesState = { loaded }
        }
        await store.send(.toggleRulesTapped) {
            $0.rulesState.enabled = true
        }
        await store.receive(\.rulesStateLoaded) {
            $0.rulesState = loaded
        }
    }

    // MARK: Editor prefill

    func test_addRuleFromFlow_prefillsEditorWithoutPersisting() async {
        let flow = Fixtures.flow()
        var initial = AppFeature.State()
        initial.flows = [flow]
        let store = TestStore(initialState: initial) { AppFeature() }
        store.exhaustivity = .off // the prefilled rule carries a fresh UUID/date

        await store.send(.addRuleFromFlow(flow.id, .mockResponse))
        XCTAssertTrue(store.state.editingRuleIsNew)
        guard case .mock = store.state.editingRule?.actions.route else {
            return XCTFail("expected a mock rule prefilled from the flow")
        }
    }

    func test_addRuleFromFlow_unknownID_isNoOp() async {
        let store = TestStore(initialState: AppFeature.State()) { AppFeature() }
        await store.send(.addRuleFromFlow(UUID(), .blockURL)) // no flow → nothing happens
    }

    func test_newRuleTapped_opensEmptyEditor() async {
        let store = TestStore(initialState: AppFeature.State()) { AppFeature() }
        store.exhaustivity = .off
        await store.send(.newRuleTapped)
        XCTAssertTrue(store.state.editingRuleIsNew)
        XCTAssertEqual(store.state.editingRule?.name, "")
    }

    // MARK: Replay

    func test_replayFinished_insertsAndSelects() async {
        let original = UUID()
        let replayed = Fixtures.flow(id: UUID(), replayedFrom: original)
        let store = TestStore(initialState: AppFeature.State()) { AppFeature() }
        await store.send(.replayFinished(replayed)) {
            $0.flows[id: replayed.id] = replayed
            $0.selectedFlowID = replayed.id // jump to the replayed result
            $0.status.capturedCount = 1
        }
    }

    func test_replayFinished_nil_isNoOp() async {
        let store = TestStore(initialState: AppFeature.State()) { AppFeature() }
        await store.send(.replayFinished(nil))
    }

    // MARK: Capture stream + clear

    func test_flowReceived_appendsAndCounts() async {
        let flow = Fixtures.flow()
        let store = TestStore(initialState: AppFeature.State()) { AppFeature() }
        await store.send(.flowReceived(flow)) {
            $0.flows[id: flow.id] = flow
            $0.status.capturedCount = 1
        }
    }

    func test_clearTapped_emptiesStore() async {
        let flow = Fixtures.flow()
        var initial = AppFeature.State()
        initial.flows = [flow]
        initial.selectedFlowID = flow.id
        initial.status.capturedCount = 1
        let store = TestStore(initialState: initial) {
            AppFeature()
        } withDependencies: {
            $0.proxyClient.clearFlows = { }
        }
        await store.send(.clearTapped) {
            $0.flows = []
            $0.selectedFlowID = nil
            $0.status.capturedCount = 0
        }
    }

    func test_toggleRecording_flips() async {
        let store = TestStore(initialState: AppFeature.State()) {
            AppFeature()
        } withDependencies: {
            $0.proxyClient.setRecording = { _ in }
        }
        await store.send(.toggleRecordingTapped) {
            $0.isRecording = false // starts true
        }
    }
}
