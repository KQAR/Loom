import SwiftUI

/// A one-line, copyable URL. Padding is the caller's: this bar sits in the
/// inspector header beside the close control, and those two must share one
/// inset rather than stacking two.
///
/// Copy lives on the right-click menu, not a trailing button — a control here
/// would sit in the gap `{md}` keeps between the URL and ✕. Truncation is the
/// text's job when the parent offers less than the URL's ideal width.
///
/// Scheme, host, path and query are tinted (`URLHighlight`) so each is a glance
/// rather than a scan of one grey line. Punctuation stays secondary; a string
/// that is not an absolute URL is left plain.
struct CopyableURLBar: View {
    let url: String
    @State private var override: String?

    private var displayed: String { override ?? url }

    var body: some View {
        Text(Self.highlighted(displayed))
            .font(.callout.monospaced())
            .lineLimit(1)
            .truncationMode(.middle)
            .textSelection(.enabled)
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            .layoutPriority(1)
            .overlay {
                WireTextHostOverlay(
                    displayed: displayed,
                    hasOverride: override != nil,
                    onDecode: { override = $0 },
                    onShowOriginal: { override = nil }
                )
            }
            .accessibilityAction(named: "Copy") {
                WireTextPasteboard.copy(displayed)
            }
            .onChange(of: url) { override = nil }
    }

    /// The captured URL with its four roles tinted. Cost is one short string —
    /// this is the inspector header, never a table row.
    static func highlighted(_ url: String) -> AttributedString {
        var attributed = AttributedString(url)
        let spans = URLHighlight.spans(in: url)
        guard !spans.isEmpty else { return attributed }
        attributed.foregroundColor = Color.secondary
        for span in spans {
            guard let lower = AttributedString.Index(span.range.lowerBound, within: attributed),
                  let upper = AttributedString.Index(span.range.upperBound, within: attributed)
            else { continue }
            attributed[lower..<upper].foregroundColor = color(for: span.role)
        }
        return attributed
    }

    static func color(for role: URLHighlight.Role) -> Color {
        switch role {
        case .scheme: LoomTheme.Palette.Syntax.name
        case .host: LoomTheme.Palette.accent
        case .path: LoomTheme.Palette.Syntax.string
        case .query: LoomTheme.Palette.Syntax.number
        }
    }
}
