import ComposableArchitecture
import LoomSharedModels

/// The modal rule editor as a presented child feature. The actual field editing
/// lives in `RuleEditorView` (SwiftUI `@State` over a `RuleDraft`); this feature
/// just holds the rule being edited and relays the human's Save/Cancel decision
/// back to `RulesFeature` as delegate actions. Modeling it with `@Presents` gives
/// the sheet a single source of truth instead of the old hand-rolled binding.
@Reducer
public struct RuleEditorFeature: Sendable {
    @ObservableState
    public struct State: Equatable {
        /// The rule being edited — prefilled for an edit, a blank template for New,
        /// or stamped from a captured flow for "Add Rule".
        public var rule: TrafficRule
        /// Add (append) vs update (replace) on save; drives the title and the
        /// "make it live" master-switch flip.
        public var isNew: Bool
        /// Distinct group names already in use, for the editor's group dropdown.
        public var existingGroups: [String]

        public init(rule: TrafficRule, isNew: Bool, existingGroups: [String]) {
            self.rule = rule
            self.isNew = isNew
            self.existingGroups = existingGroups
        }
    }

    public enum Action: Sendable {
        case delegate(Delegate)
        public enum Delegate: Sendable {
            /// The human hit Save and the draft built into a valid rule.
            case save(TrafficRule, isNew: Bool)
            /// The human dismissed the editor without saving.
            case cancel
        }
    }

    public init() {}

    public var body: some ReducerOf<Self> {
        Reduce { _, action in
            switch action {
            case .delegate:
                return .none // handled by the parent RulesFeature
            }
        }
    }
}
