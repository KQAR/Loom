import SwiftUI

/// The small-payload raw view: monospaced text with a leading line-number
/// gutter, and the message head syntax-highlighted (`HTTPHeadHighlight`).
///
/// The highlighting is built into an `AttributedString` once per text change
/// rather than per line: a `Text` per line would give SwiftUI one view per line
/// to lay out and would break selection across them, which is most of what this
/// pane is for.
struct SmallRawText: View {
    let text: String
    /// Hits measured against `text` by whoever owns the body — this view does
    /// not scan, so the pane and its `1/N` cannot disagree and a keystroke
    /// costs one pass rather than one per view that draws it.
    var findRanges: [Range<String.Index>] = []
    var findIndex: Int = 0
    @State private var override: String?

    private var displayed: String { override ?? text }

    var body: some View {
        let lines = displayed.isEmpty ? [""] : displayed.components(separatedBy: "\n")
        HStack(alignment: .top, spacing: LoomTheme.Space.sm) {
            Text((1 ... lines.count).map(String.init).joined(separator: "\n"))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.trailing)
            // Ranges were measured on `text`; a decoded view is a different
            // string, so it gets no wash rather than a wash on the wrong bytes.
            Text(Self.highlighted(displayed, ranges: override == nil ? findRanges : [], current: findIndex))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay {
                    WireTextHostOverlay(
                        displayed: displayed,
                        hasOverride: override != nil,
                        onDecode: { override = $0 },
                        onShowOriginal: { override = nil }
                    )
                }
        }
        .font(.callout.monospaced())
        .onChange(of: text) { override = nil }
    }

    /// The raw text with the head's spans tinted, then the given find ranges
    /// washed. Only the head is foreground-tinted, so the cost is a few hundred
    /// bytes however large the body is; the find backgrounds are a pass over
    /// the supplied matches, not a scan of the whole string.
    static func highlighted(
        _ text: String, ranges: [Range<String.Index>] = [], current: Int = 0
    ) -> AttributedString {
        var attributed = AttributedString(text)
        for span in HTTPHeadHighlight.spans(in: text) {
            guard let lower = AttributedString.Index(span.range.lowerBound, within: attributed),
                  let upper = AttributedString.Index(span.range.upperBound, within: attributed)
            else { continue }
            attributed[lower ..< upper].foregroundColor = color(for: span.role)
        }
        for (i, range) in ranges.enumerated() {
            guard let lower = AttributedString.Index(range.lowerBound, within: attributed),
                  let upper = AttributedString.Index(range.upperBound, within: attributed)
            else { continue }
            attributed[lower ..< upper].backgroundColor = i == current
                ? InspectorText.FindWash.current
                : InspectorText.FindWash.other
        }
        return attributed
    }

    static func color(for role: HTTPHeadHighlight.Role) -> Color {
        switch role {
        // The same functions the table's Method column, the status dot and the
        // badges use — a Raw pane inventing its own red is the parity bug
        // DESIGN.md § inspector-parity exists to prevent.
        case let .method(method): LoomTheme.methodColor(method)
        case let .status(code): LoomTheme.statusColor(status: code, isError: false)
        case .headerName: LoomTheme.Palette.Syntax.name
        }
    }
}
