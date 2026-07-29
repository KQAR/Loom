import AppKit
import SwiftUI

/// Floating copy button pinned to the top-right of a body pane; copies the whole
/// body and briefly flips to a checkmark for feedback.
struct FloatingCopyButton: View {
    let text: String
    @State private var copied = false

    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            copied = true
        } label: {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                .font(.callout)
                .foregroundStyle(copied ? Color.accentColor : .secondary)
                .padding(6)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: LoomTheme.Radius.sm))
                .overlay {
                    RoundedRectangle(cornerRadius: LoomTheme.Radius.sm)
                        .stroke(.quaternary, lineWidth: 1)
                }
        }
        .buttonStyle(.plain)
        // Revert the checkmark on a task tied to the view, not a bare
        // `asyncAfter`: switching flows (or closing the inspector) tears the view
        // down, and an uncancellable timer would still be holding the closure and
        // writing `@State` on a view that is gone.
        .task(id: copied) {
            guard copied else { return }
            try? await Task.sleep(for: .seconds(1.2))
            copied = false
        }
        .accessibilityLabel("Copy body")
        .help("Copy body")
        .padding(LoomTheme.Space.sm)
    }
}
