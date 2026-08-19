import AppKit
import SwiftUI

/// Read-only monospaced text viewer backed by `NSTextView`. Unlike SwiftUI
/// `Text` (which lays its entire string out synchronously), TextKit lays out
/// only the visible viewport, so multi-megabyte bodies scroll smoothly while
/// keeping native selection and copy. In-pane find is the search button beside
/// Copy, not ⌘F (that is the window's "Find in Requests"). Owns its own
/// `NSScrollView` — do not nest it inside a SwiftUI `ScrollView`.
struct CodeTextView: NSViewRepresentable {
    let text: String
    /// Changes iff `text` changes; lets `updateNSView` skip re-pushing the
    /// (potentially huge) string on unrelated re-renders.
    let identity: AnyHashable
    var findNeedle: String = ""
    var findIndex: Int = 0

    func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor
    final class Coordinator {
        var applied: AnyHashable?
        var appliedFind: (needle: String, index: Int)?
        let host = WireTextHost()

        func bind(_ textView: NSTextView, original: String) {
            WireTextSystemMenu.install()
            host.displayed = textView.string
            host.hasOverride = textView.string != original
            host.onDecode = { [weak textView] decoded in
                guard let textView else { return }
                textView.string = decoded
                WireTextSystemMenu.selectAll(textView)
            }
            host.onShowOriginal = { [weak textView] in
                guard let textView else { return }
                textView.string = original
                WireTextSystemMenu.selectAll(textView)
            }
            textView.wireHost = host
        }
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
        // Native Find is the window's "Find in Requests" (⌘F). In-pane find is
        // the search button next to Copy; it highlights via `applyFind`.
        textView.usesFindBar = false
        textView.isIncrementalSearchingEnabled = false
        textView.textContainerInset = NSSize(width: LoomTheme.Space.md, height: LoomTheme.Space.sm)
        // Wrap long lines to the pane width (minified JSON can be one huge line).
        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true
        textView.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        textView.textColor = .textColor

        apply(text, to: textView)
        context.coordinator.bind(textView, original: text)
        context.coordinator.applied = identity
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let textView = scroll.documentView as? NSTextView else { return }
        if context.coordinator.applied != identity {
            apply(text, to: textView)
            context.coordinator.bind(textView, original: text)
            context.coordinator.applied = identity
            context.coordinator.appliedFind = nil
        } else {
            context.coordinator.bind(textView, original: text)
        }
        applyFind(to: textView, coordinator: context.coordinator)
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

    /// Background-highlight find ranges without touching the head's foreground
    /// tints. Other hits and the current one share the find yellow; the current
    /// hit is the same hue at a higher opacity.
    private func applyFind(to textView: NSTextView, coordinator: Coordinator) {
        let needle = findNeedle
        let index = findIndex
        if coordinator.appliedFind?.needle == needle, coordinator.appliedFind?.index == index {
            return
        }
        coordinator.appliedFind = (needle, index)
        guard let storage = textView.textStorage else { return }
        let whole = NSRange(location: 0, length: storage.length)
        storage.removeAttribute(.backgroundColor, range: whole)
        guard !needle.isEmpty else { return }
        let matches = InspectorFindMatch.ranges(of: needle, in: text)
        let other = InspectorText.FindWash.otherNS
        let current = InspectorText.FindWash.currentNS
        for (i, range) in matches.enumerated() {
            let nsRange = NSRange(range, in: text)
            guard nsRange.location != NSNotFound, NSMaxRange(nsRange) <= storage.length else { continue }
            storage.addAttribute(.backgroundColor, value: i == index ? current : other, range: nsRange)
        }
        if matches.indices.contains(index) {
            let nsRange = NSRange(matches[index], in: text)
            guard nsRange.location != NSNotFound else { return }
            textView.scrollRangeToVisible(nsRange)
            textView.showFindIndicator(for: nsRange)
        }
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
