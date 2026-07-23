import ComposableArchitecture
import ProxyClient
import SharedModels

/// The traffic-rules surface, split out of `AppFeature`: the rule set mirrored
/// from the engine, the presented editor, and every rule write. The agent authors
/// rules over MCP; here the human supervises them (master switch, per-rule/per-group
/// toggles, edit, delete). Every write is optimistic then re-synced from the engine,
/// so a rejected write reverts to engine truth. `AppFeature` embeds this via `Scope`
/// and keeps flow capture/selection/pins in the parent.
@Reducer
public struct RulesFeature: Sendable {
    @ObservableState
    public struct State: Equatable {
        /// Rule-engine config, mirrored from the engine (which persists it).
        /// Loaded at boot and re-synced when the panel opens or a write completes.
        public var rulesState = RulesState()
        /// Transient error shown in the Rules panel when a rule write (or a replay,
        /// routed here by the parent) fails, so a failure isn't silently swallowed.
        /// Cleared when the next write starts.
        public var rulesMessage: String?
        /// The presented rule editor (nil = closed).
        @Presents public var editor: RuleEditorFeature.State?

        public var rulesEnabled: Bool { rulesState.enabled }
        /// Names of rules that currently apply — empty when the master switch is off.
        public var enabledRules: [String] { rulesState.activeRules.map(\.name) }

        /// Distinct group names already in use, in first-appearance order.
        public var existingGroups: [String] {
            var seen = Set<String>()
            return rulesState.rules.compactMap(\.group).filter { seen.insert($0).inserted }
        }

        public init() {}
    }

    public enum Action: Sendable {
        case editor(PresentationAction<RuleEditorFeature.Action>)
        /// A rule/replay write failed; surface the reason in the panel.
        case ruleWriteFailed(String)
        case rulesStateLoaded(RulesState)
        /// Cheap re-sync when the panel appears.
        case refreshRules
        /// Open the editor prefilled with `rule` (used by the parent's "Add Rule
        /// from flow", which needs the parent-owned flow store to build the rule).
        case presentEditor(rule: TrafficRule, isNew: Bool)
        case newRuleTapped
        case editRuleTapped(TrafficRule.ID)
        case ruleToggled(TrafficRule.ID)
        case ruleDeleted(TrafficRule.ID)
        case ruleGroupToggled(group: String?, enabled: Bool)
        case toggleRulesTapped
    }

    @Dependency(\.proxyClient) var proxyClient

    public init() {}

    public var body: some ReducerOf<Self> {
        Reduce { state, action in
            switch action {
            // MARK: Editor lifecycle

            case let .presentEditor(rule, isNew):
                state.editor = RuleEditorFeature.State(rule: rule, isNew: isNew, existingGroups: state.existingGroups)
                return .none

            case .newRuleTapped:
                let blank = TrafficRule(name: "", match: RuleMatch(urlPattern: ""), actions: RuleActions())
                state.editor = RuleEditorFeature.State(rule: blank, isNew: true, existingGroups: state.existingGroups)
                return .none

            case let .editRuleTapped(id):
                guard let rule = state.rulesState.rules.first(where: { $0.id == id }) else { return .none }
                state.editor = RuleEditorFeature.State(rule: rule, isNew: false, existingGroups: state.existingGroups)
                return .none

            case let .editor(.presented(.delegate(.save(rule, isNew)))):
                state.editor = nil
                state.rulesMessage = nil
                if isNew {
                    // Saving a new rule means "make it live now": flip the master
                    // switch too so it isn't silently inert.
                    state.rulesState.enabled = true
                    state.rulesState.rules.append(rule) // optimistic; re-synced below
                    return .run { send in
                        await proxyClient.setRulesEnabled(true)
                        do { try await proxyClient.addRule(rule) }
                        catch { await send(.ruleWriteFailed("Couldn’t save rule: \(error.localizedDescription)")) }
                        await send(.rulesStateLoaded(proxyClient.rulesState()))
                    }
                }
                if let index = state.rulesState.rules.firstIndex(where: { $0.id == rule.id }) {
                    state.rulesState.rules[index] = rule
                }
                return .run { send in
                    do { try await proxyClient.updateRule(rule) }
                    catch { await send(.ruleWriteFailed("Couldn’t update rule: \(error.localizedDescription)")) }
                    await send(.rulesStateLoaded(proxyClient.rulesState()))
                }

            case .editor(.presented(.delegate(.cancel))), .editor(.dismiss):
                state.editor = nil
                return .none

            case .editor:
                return .none

            // MARK: Rule CRUD

            case let .ruleToggled(id):
                guard var rule = state.rulesState.rules.first(where: { $0.id == id }) else { return .none }
                rule.isEnabled.toggle()
                let updated = rule
                state.rulesMessage = nil
                return .run { send in
                    do { try await proxyClient.updateRule(updated) }
                    catch { await send(.ruleWriteFailed("Couldn’t toggle rule: \(error.localizedDescription)")) }
                    await send(.rulesStateLoaded(proxyClient.rulesState()))
                }

            case let .ruleDeleted(id):
                state.rulesMessage = nil
                return .run { send in
                    do { try await proxyClient.deleteRule(id) }
                    catch { await send(.ruleWriteFailed("Couldn’t delete rule: \(error.localizedDescription)")) }
                    await send(.rulesStateLoaded(proxyClient.rulesState()))
                }

            case let .ruleGroupToggled(group, enabled):
                return .run { send in
                    await proxyClient.setGroupEnabled(group, enabled)
                    await send(.rulesStateLoaded(proxyClient.rulesState()))
                }

            case .toggleRulesTapped:
                let enabling = !state.rulesState.enabled
                state.rulesState.enabled = enabling // optimistic; re-synced below
                return .run { send in
                    await proxyClient.setRulesEnabled(enabling)
                    await send(.rulesStateLoaded(proxyClient.rulesState()))
                }

            // MARK: Sync

            case let .rulesStateLoaded(rulesState):
                state.rulesState = rulesState
                return .none

            case .refreshRules:
                return .run { send in
                    await send(.rulesStateLoaded(proxyClient.rulesState()))
                }

            case let .ruleWriteFailed(message):
                state.rulesMessage = message
                return .none
            }
        }
        .ifLet(\.$editor, action: \.editor) {
            RuleEditorFeature()
        }
    }
}
