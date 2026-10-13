import Foundation


/// One derived value remembered across renders, recomputed only when its key changes.
///
/// An open inspector re-renders on every capture batch touching the selected flow
/// (~100 ms while it streams), on every find keystroke and on every preference the body
/// reports up — and each render re-derived everything from scratch: a JSON parse of
/// the request body to decide whether a GraphQL tab exists, and a UTF-8 decode of the
/// whole body (up to 5 MB) to decide whether the copy button does. Neither answer
/// changes unless the body does.
///
/// A class held in `@State`, so updating it during `body` is not a state change and
/// triggers nothing. The memoised value is also the *same instance* render to render,
/// which lets SwiftUI's comparison of a large `String` argument stop at its storage
/// identity instead of walking it.
@MainActor
final class RenderMemo<Key: Equatable, Value> {
    private var cached: (key: Key, value: Value)?

    func value(for key: Key, _ make: () -> Value) -> Value {
        if let cached, cached.key == key { return cached.value }
        let value = make()
        cached = (key, value)
        return value
    }
}

/// What a body-derived value depends on: which flow, and how much body it has. A body
/// only ever grows while it streams, so the count changing is the body changing.
struct BodyMemoKey: Equatable {
    var flowID: UUID
    var bytes: Int?
}
