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

    var body: some View {
        let lines = text.isEmpty ? [""] : text.components(separatedBy: "\n")
        HStack(alignment: .top, spacing: LoomTheme.Space.sm) {
            Text((1 ... lines.count).map(String.init).joined(separator: "\n"))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.trailing)
            Text(Self.highlighted(text))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.callout.monospaced())
    }

    /// The raw text with the head's spans tinted. Only the head is touched, so
    /// the cost is a few hundred bytes however large the body is.
    static func highlighted(_ text: String) -> AttributedString {
        var attributed = AttributedString(text)
        for span in HTTPHeadHighlight.spans(in: text) {
            guard let lower = AttributedString.Index(span.range.lowerBound, within: attributed),
                  let upper = AttributedString.Index(span.range.upperBound, within: attributed)
            else { continue }
            attributed[lower ..< upper].foregroundColor = color(for: span.role)
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
