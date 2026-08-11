import Foundation
import LoomSharedModels

/// One editable query predicate row.
///
/// The editor keeps typing it as text — `*` in the value box still means "any
/// value", which is the shorthand people type — and converts at the boundary,
/// so the model holds a `QueryPredicate` and the row holds a string. The one
/// thing the shorthand cannot say (a value that *is* `*`) stays reachable
/// through MCP; spending a control on it here would cost every user a mode
/// switch for a case none of them has.
struct QueryItem: Identifiable, Equatable {
    let id = UUID()
    var key: String
    var value: String

    init(key: String, value: String) {
        self.key = key
        self.value = value
    }

    init(key: String, predicate: QueryPredicate) {
        self.key = key
        switch predicate {
        case .present: value = "*"
        case let .equals(text): value = text
        }
    }

    var predicate: QueryPredicate { QueryPredicate(legacyWireValue: value) }
}
