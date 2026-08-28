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
    /// Hits measured against `text` by whoever owns the body. Scanning here as
    /// well is what made a keystroke cost a second full pass over a body that
    /// can be 5 MB.
    var findRanges: [Range<String.Index>] = []
    var findIndex: Int = 0
    /// Text container inset. Defaults to the pane's own margins; a caller that has
    /// already padded around this view passes `.zero`, so the text lines up with
    /// whatever is above it instead of sitting a margin further in.
    var textInset = NSSize(width: LoomTheme.Space.md, height: LoomTheme.Space.sm)

    func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor
    final class Coordinator {
        var applied: AnyHashable?
        var appliedFind: Highlight?
        /// The decoded string currently shown, nil = showing the capture.
        ///
        /// Held here rather than re-derived by comparing `textView.string` with
        /// the capture: `bind` runs on **every** update, that read is an
        /// `NSString` bridge and the comparison walks the whole document — up
        /// to 5 MB, ~10×/s while a body streams, whether or not find is open.
        var overridden: String?
        private var original = ""
        private var wired = false
        let host = WireTextHost()

        struct Highlight: Equatable {
            var ranges: [Range<String.Index>] = []
            var index = 0
        }

        func bind(_ textView: NSTextView, original: String) {
            self.original = original
            host.displayed = overridden ?? original
            host.hasOverride = overridden != nil
            textView.wireHost = host
            guard !wired else { return }
            wired = true
            // Read `self.original` at call time rather than capturing it, so a
            // streaming body that grows does not need the closures rebuilt.
            host.onDecode = { [weak self, weak textView] decoded in
                guard let self, let textView else { return }
                overridden = decoded
                host.displayed = decoded
                host.hasOverride = true
                textView.string = decoded
                WireTextSystemMenu.selectAll(textView)
            }
            host.onShowOriginal = { [weak self, weak textView] in
                guard let self, let textView else { return }
                overridden = nil
                host.displayed = self.original
                host.hasOverride = false
                textView.string = self.original
                WireTextSystemMenu.selectAll(textView)
            }
        }
    }

    func makeNSView(context: Context) -> NSScrollView {
        WireTextSystemMenu.install()
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
        textView.textContainerInset = textInset
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
        textView.textContainerInset = textInset
        let coordinator = context.coordinator
        if coordinator.applied != identity {
            coordinator.overridden = nil
            coordinator.appliedFind = nil
            apply(text, to: textView)
            coordinator.applied = identity
        }
        coordinator.bind(textView, original: text)
        applyFind(to: textView, coordinator: coordinator)
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

    /// Background-highlight the supplied find ranges without touching the head's
    /// foreground tints. Other hits and the current one share the find yellow;
    /// the current hit is the same hue at a higher opacity.
    private func applyFind(to textView: NSTextView, coordinator: Coordinator) {
        // A decoded view is a different string from the one the ranges were
        // measured on, so it gets no wash rather than a wash on the wrong
        // characters.
        let wanted = coordinator.overridden == nil
            ? Coordinator.Highlight(ranges: findRanges, index: findIndex)
            : Coordinator.Highlight()
        guard coordinator.appliedFind != wanted else { return }
        coordinator.appliedFind = wanted
        guard let storage = textView.textStorage else { return }
        let whole = NSRange(location: 0, length: storage.length)
        storage.removeAttribute(.backgroundColor, range: whole)
        guard !wanted.ranges.isEmpty else { return }
        let other = InspectorText.FindWash.otherNS
        let current = InspectorText.FindWash.currentNS
        for (i, range) in wanted.ranges.enumerated() {
            let nsRange = NSRange(range, in: text)
            guard nsRange.location != NSNotFound, NSMaxRange(nsRange) <= storage.length else { continue }
            storage.addAttribute(.backgroundColor, value: i == wanted.index ? current : other, range: nsRange)
        }
        if wanted.ranges.indices.contains(wanted.index) {
            let nsRange = NSRange(wanted.ranges[wanted.index], in: text)
            guard nsRange.location != NSNotFound, NSMaxRange(nsRange) <= storage.length else { return }
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
