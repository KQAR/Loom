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

    /// Set the whole string in one shot with the fixed monospaced attributes, then
    /// tint the message head.
    ///
    /// Attributes are added over the head's ranges rather than by building an
    /// `NSAttributedString` for the whole document: this view exists for payloads
    /// measured in megabytes, and attributing all of them to colour a few hundred
    /// bytes would undo the reason it is an `NSTextView` at all.
    private func apply(_ text: String, to textView: NSTextView) {
        textView.string = text
        textView.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        textView.textColor = .textColor
        highlightHead(of: text, in: textView)
        textView.scroll(.zero)
    }

    private func highlightHead(of text: String, in textView: NSTextView) {
        guard let storage = textView.textStorage else { return }
        for span in HTTPHeadHighlight.spans(in: text) {
            let range = NSRange(span.range, in: text)
            guard range.location != NSNotFound, NSMaxRange(range) <= storage.length else { continue }
            storage.addAttribute(
                .foregroundColor,
                value: NSColor(SmallRawText.color(for: span.role)),
                range: range
            )
        }
    }
}
