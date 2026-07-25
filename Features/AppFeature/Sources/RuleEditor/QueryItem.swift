import Foundation
import LoomSharedModels

/// One editable query predicate row. `value` of `*` means presence-only (any
/// value), matching `RuleMatch.query` semantics.
struct QueryItem: Identifiable, Equatable {
    let id = UUID()
    var key: String
    var value: String
}
