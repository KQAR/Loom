import AppKit
import SwiftUI

/// Read-only monospaced text viewer backed by `NSTextView`. Unlike SwiftUI
/// `Text` (which lays its entire string out synchronously), TextKit lays out
/// only the visible viewport, so multi-megabyte bodies scroll smoothly while
/// keeping native selection, Find (⌘F) and copy. Owns its own `NSScrollView` —
/// do not nest it inside a SwiftUI `ScrollView`.
struct CodeTextView: NSViewRepresentable {
    let text: String
    /// Changes iff `text` changes; lets `updateNSView` skip re-pushing the
    /// (potentially huge) string on unrelated re-renders.
    let identity: AnyHashable

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var applied: AnyHashable?
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        guard let textView = scroll.documentView as? NSTextView else { return scroll }

        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.drawsBackground = false
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.textContainerInset = NSSize(width: LoomTheme.Space.md, height: LoomTheme.Space.sm)
        // Wrap long lines to the pane width (minified JSON can be one huge line).
        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true
        textView.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        textView.textColor = .textColor

        apply(text, to: textView)
        context.coordinator.applied = identity
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let textView = scroll.documentView as? NSTextView else { return }
        guard context.coordinator.applied != identity else { return }
        apply(text, to: textView)
        context.coordinator.applied = identity
    }

    /// Set the whole string in one shot with the fixed monospaced attributes.
    private func apply(_ text: String, to textView: NSTextView) {
        textView.string = text
        textView.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        textView.textColor = .textColor
        textView.scroll(.zero)
    }
}
