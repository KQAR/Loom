import ComposableArchitecture
import Foundation
import LoomSharedModels
import Testing

@testable import AppFeature

/// `TestStore` coverage for the extracted `RulesFeature`: the editor lifecycle
/// (present / save / cancel) and the optimistic-write-then-resync path for every
/// rule mutation. Each write is asserted to adopt engine truth over the optimistic
/// guess (the engine's returned state is made observably different).
@MainActor
@Suite struct RulesFeatureTests {
    private struct StubError: LocalizedError {
        var errorDescription: String? { "save failed" }
    }

    // MARK: Editor presentation

    @Test func test_presentEditor_opensWithGivenRule() async {
        let rule = Fixtures.rule(name: "From flow")
        let store = TestStore(initialState: RulesFeature.State()) { RulesFeature() }
        await store.send(.presentEditor(rule: rule, isNew: true)) {
            $0.editor = RuleEditorFeature.State(rule: rule, isNew: true, existingGroups: [])
        }
    }

    @Test func test_editRuleTapped_opensPrefilledFromExisting() async {
        let rule = Fixtures.rule(group: "scenario-a")
        var initial = RulesFeature.State()
        initial.rulesState = RulesState(enabled: true, rules: [rule])
        let store = TestStore(initialState: initial) { RulesFeature() }
        await store.send(.editRuleTapped(rule.id)) {
            $0.editor = RuleEditorFeature.State(rule: rule, isNew: false, existingGroups: ["scenario-a"])
        }
    }

    @Test func test_editRuleTapped_unknownID_isNoOp() async {
        let store = TestStore(initialState: RulesFeature.State()) { RulesFeature() }
        await store.send(.editRuleTapped(UUID()))
    }

    @Test func test_newRuleTapped_opensEmptyEditor() async {
        let store = TestStore(initialState: RulesFeature.State()) { RulesFeature() }
        store.exhaustivity = .off // the blank rule carries a fresh UUID/date
        await store.send(.newRuleTapped)
        #expect(store.state.editor?.isNew ?? false)
        #expect(store.state.editor?.rule.name == "")
    }

    @Test func test_editorCancel_closesEditor() async {
        let rule = Fixtures.rule()
        var initial = RulesFeature.State()
        initial.editor = RuleEditorFeature.State(rule: rule, isNew: false, existingGroups: [])
        let store = TestStore(initialState: initial) { RulesFeature() }
        await store.send(.editor(.presented(.delegate(.cancel)))) {
            $0.editor = nil
        }
    }

    // MARK: Editor save — new

    @Test func test_editorSave_new_optimisticAppend_flipsMasterSwitch_thenResyncs() async {
        let rule = Fixtures.rule(name: "Block home")
        var initial = RulesFeature.State()
        initial.editor = RuleEditorFeature.State(rule: rule, isNew: true, existingGroups: [])
        initial.rulesState = RulesState(enabled: false, rules: [])
        initial.rulesMessage = "stale error"

        // Engine truth differs from the optimistic guess (it annotated the rule).
        var synced = rule
        synced.comment = "persisted"
        let loaded = RulesState(enabled: true, rules: [synced])
        let store = TestStore(initialState: initial) {
            RulesFeature()
        } withDependencies: {
            $0.proxyClient.setRulesEnabled = { _ in }
            $0.proxyClient.addRule = { _ in }
            $0.proxyClient.rulesState = { loaded }
        }

        await store.send(.editor(.presented(.delegate(.save(rule, isNew: true))))) {
            $0.editor = nil
            $0.rulesMessage = nil
            $0.rulesState.enabled = true          // saving a new rule makes the engine live
            $0.rulesState.rules = [rule]           // optimistic append before the re-sync
        }
        await store.receive(\.rulesStateLoaded) {
            $0.rulesState = loaded
        }
    }

    @Test func test_editorSave_new_addRuleThrows_surfacesMessage() async {
        let rule = Fixtures.rule()
        var initial = RulesFeature.State()
        initial.editor = RuleEditorFeature.State(rule: rule, isNew: true, existingGroups: [])
        initial.rulesState = RulesState(enabled: false, rules: [])

        let loaded = RulesState(enabled: true, rules: []) // engine rejected the write
        let store = TestStore(initialState: initial) {
            RulesFeature()
        } withDependencies: {
            $0.proxyClient.setRulesEnabled = { _ in }
            $0.proxyClient.addRule = { _ in throw StubError() }
            $0.proxyClient.rulesState = { loaded }
        }

        await store.send(.editor(.presented(.delegate(.save(rule, isNew: true))))) {
            $0.editor = nil
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

    // MARK: Editor save — update

    @Test func test_editorSave_update_replacesInPlace_thenResyncs() async {
        let id = UUID()
        let original = Fixtures.rule(id: id, name: "Original")
        var edited = original
        edited.name = "Edited"

        var initial = RulesFeature.State()
        initial.editor = RuleEditorFeature.State(rule: edited, isNew: false, existingGroups: [])
        initial.rulesState = RulesState(enabled: true, rules: [original])

        var synced = edited
        synced.comment = "persisted" // engine truth differs from the optimistic replace
        let loaded = RulesState(enabled: true, rules: [synced])
        let store = TestStore(initialState: initial) {
            RulesFeature()
        } withDependencies: {
            $0.proxyClient.updateRule = { _ in }
            $0.proxyClient.rulesState = { loaded }
        }

        await store.send(.editor(.presented(.delegate(.save(edited, isNew: false))))) {
            $0.editor = nil
            $0.rulesMessage = nil
            $0.rulesState.rules = [edited]
        }
        await store.receive(\.rulesStateLoaded) {
            $0.rulesState = loaded
        }
    }

    // MARK: Master switch + per-rule/group writes

    @Test func test_toggleRulesTapped_optimisticFlip_thenResyncs() async {
        var initial = RulesFeature.State()
        initial.rulesState = RulesState(enabled: false, rules: [])
        let loaded = RulesState(enabled: true, rules: [Fixtures.rule()])
        let store = TestStore(initialState: initial) {
            RulesFeature()
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

    @Test func test_ruleToggled_flipsEnabled_thenResyncs() async {
        let rule = Fixtures.rule(isEnabled: true)
        var initial = RulesFeature.State()
        initial.rulesState = RulesState(enabled: true, rules: [rule])
        var toggled = rule
        toggled.isEnabled = false
        let loaded = RulesState(enabled: true, rules: [toggled])
        let store = TestStore(initialState: initial) {
            RulesFeature()
        } withDependencies: {
            $0.proxyClient.updateRule = { _ in }
            $0.proxyClient.rulesState = { loaded }
        }
        await store.send(.ruleToggled(rule.id))
        await store.receive(\.rulesStateLoaded) {
            $0.rulesState = loaded
        }
    }

    @Test func test_ruleDeleted_resyncs() async {
        let rule = Fixtures.rule()
        var initial = RulesFeature.State()
        initial.rulesState = RulesState(enabled: true, rules: [rule])
        let loaded = RulesState(enabled: true, rules: [])
        let store = TestStore(initialState: initial) {
            RulesFeature()
        } withDependencies: {
            $0.proxyClient.deleteRule = { _ in }
            $0.proxyClient.rulesState = { loaded }
        }
        await store.send(.ruleDeleted(rule.id))
        await store.receive(\.rulesStateLoaded) {
            $0.rulesState = loaded
        }
    }

    @Test func test_ruleWriteFailed_setsMessage() async {
        let store = TestStore(initialState: RulesFeature.State()) { RulesFeature() }
        await store.send(.ruleWriteFailed("boom")) {
            $0.rulesMessage = "boom"
        }
    }
}
