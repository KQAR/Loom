import SwiftUI

/// The small-payload raw view: monospaced text with a leading line-number
/// gutter.
struct SmallRawText: View {
    let text: String
    var body: some View {
        let lines = text.isEmpty ? [""] : text.components(separatedBy: "\n")
        HStack(alignment: .top, spacing: LoomTheme.Space.sm) {
            Text((1...lines.count).map(String.init).joined(separator: "\n"))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.trailing)
            Text(lines.joined(separator: "\n"))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.callout.monospaced())
    }
}
