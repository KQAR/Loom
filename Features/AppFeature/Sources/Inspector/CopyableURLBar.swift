import AppKit
import SwiftUI

struct CopyableURLBar: View {
    let url: String
    var body: some View {
        HStack(spacing: LoomTheme.Space.xs) {
            Text(url)
                .font(.callout.monospaced())
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
            Spacer(minLength: LoomTheme.Space.xs)
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(url, forType: .string)
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .accessibilityLabel("Copy URL")
            .help("Copy URL")
        }
        .padding(.horizontal, LoomTheme.Space.md)
        .padding(.vertical, LoomTheme.Space.xs)
    }
}
