import LoomSharedModels
import SwiftUI

/// The Raw tab, memoized. Building the raw string — a UTF-8 decode of a body up
/// to the capture cap plus a header join — used to run inline in the pane's
/// content builder, i.e. on every inspector re-render: ~10×/s under live traffic
/// with a selection open. The string is now rebuilt off the main actor, and only
/// when the flow's content actually changes.
///
/// The same key doubles as `RawView`'s push identity, which also fixes a
/// staleness bug: the old identity was the flow id alone, constant across
/// streaming updates, so a large raw view (`CodeTextView` only pushes text when
/// identity changes) kept showing the first chunk while the body grew.
struct RawTab: View {
    let flow: Flow
    /// Distinguishes the two panes' identities ("req" / "resp") — both can be
    /// open on the same flow at once.
    let pane: String
    let makeText: @Sendable (Flow) -> String

    @State private var text = ""

    /// Everything the raw string is derived from: a streaming update grows the
    /// response body, hydration attaches bodies, completion stamps the outcome.
    /// Anything else leaves the string identical — no rebuild, no push.
    private struct Key: Hashable {
        let pane: String
        let id: UUID
        let requestBytes: Int?
        let responseBytes: Int?
        let completedAt: Date?
    }

    private var key: Key {
        Key(
            pane: pane,
            id: flow.id,
            requestBytes: flow.request.body?.count,
            responseBytes: flow.response?.body?.count,
            completedAt: flow.completedAt
        )
    }

    var body: some View {
        RawView(text: text, identity: key)
            .task(id: key) {
                let flow = flow
                let make = makeText
                let rebuilt = await Task.detached(priority: .userInitiated) { make(flow) }.value
                guard !Task.isCancelled else { return }
                text = rebuilt
            }
    }
}
