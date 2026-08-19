import AppKit
import SwiftUI

/// Raw text pane. Small payloads use the line-numbered SwiftUI view (`Text` is
/// fine at this size and gives the gutter for reading raw HTTP); large payloads
/// switch to `CodeTextView`, an `NSTextView` that lays out only the visible
/// viewport — the whole body renders, but the main thread never has to lay it
/// all out at once. `identity` changes exactly when the content does, so the
/// heavy text is pushed into the text view only on a real change.
struct RawView: View {
    let text: String
    let identity: AnyHashable
    /// Whether the pane's find field is open with a needle in it. Decides the
    /// *view*, which the hits alone cannot: a needle with no matches must not
    /// swap the pane back to the non-scrollable small view mid-typing.
    var findActive: Bool = false
    /// Hits measured against `text` by whoever owns the body. Never re-scanned
    /// here — this view is handed up to 5 MB and is re-rendered per keystroke.
    var findRanges: [Range<String.Index>] = []
    var findIndex: Int = 0

    var body: some View {
        // Find needs `scrollRangeToVisible`; the small SwiftUI `Text` cannot
        // scroll to a substring, so an active needle uses the text view too.
        if text.utf8.count > InspectorText.plainTextThreshold || findActive {
            CodeTextView(text: text, identity: identity, findRanges: findRanges, findIndex: findIndex)
        } else {
            Scrolled { SmallRawText(text: text, findRanges: findRanges, findIndex: findIndex) }
        }
    }
}
