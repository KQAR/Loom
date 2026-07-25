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

    var body: some View {
        if text.utf8.count > InspectorText.plainTextThreshold {
            CodeTextView(text: text, identity: identity)
        } else {
            Scrolled { SmallRawText(text: text) }
        }
    }
}
