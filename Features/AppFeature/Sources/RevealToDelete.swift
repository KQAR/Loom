import SwiftUI

/// Wraps one console list row so its trash button slides the row aside to reveal a
/// **Delete** button, which removes immediately.
///
/// Two constraints produced this shape rather than a dialog or an in-row prompt:
///
/// - The console is a `MenuBarExtra` popover, which closes the moment it stops being the
///   key window — and taking key focus is exactly what presenting a `confirmationDialog`
///   does. The dialog's buttons ended up unclickable and the orphaned presentation was
///   still waiting when the panel next opened, so a removal here can involve no second
///   window at all (DESIGN.md § console).
/// - The first fix confirmed *inside* the row — swapping the caption for a warning and
///   showing Cancel + Remove — and at 300pt that meant two truncated buttons over four
///   lines of wrapped orange text for a one-word decision. The reveal costs one row of
///   width and no height.
///
/// The reveal *is* the confirmation: the destructive button isn't reachable without the
/// deliberate first tap, and tapping the trash again (or acting on another row) puts it
/// away. So Delete acts at once — a second confirm on top of the gesture would be the
/// dialog again, in slower motion.
struct RevealToDelete<Content: View>: View {
    /// Whether this row is the one currently revealed. A binding to a shared
    /// "which row" selection, so revealing one closes any other.
    let isRevealed: Bool
    /// Reveal (or put away) this row — the trash button's action.
    let onToggle: () -> Void
    /// Delete now. No further confirmation.
    let onDelete: () -> Void
    var disabled: Bool = false
    /// The row itself, laid out full width; it is what slides.
    @ViewBuilder let content: () -> Content

    /// How far the row slides. Sized to the Delete button plus the gap it needs, and
    /// deliberately no more: the console is `LoomTheme.consoleWidth` wide and what slides
    /// out of view is the row's own leading edge.
    private static var revealWidth: CGFloat { 76 }

    var body: some View {
        ZStack(alignment: .trailing) {
            Button("Delete", action: onDelete)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .tint(.red)
                .disabled(disabled)
                .opacity(isRevealed ? 1 : 0)
                // Not just hidden: an invisible button still takes hits, and this one
                // deletes without asking again.
                .allowsHitTesting(isRevealed)

            HStack(alignment: .top, spacing: LoomTheme.Space.sm) {
                content()
                Button(action: onToggle) {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .font(.caption)
                .disabled(disabled)
                .help(isRevealed ? "Cancel" : "Remove")
            }
            .offset(x: isRevealed ? -Self.revealWidth : 0)
        }
        // The row's leading edge slides out of the card, so it has to be cut off rather
        // than drawn over the card's padding.
        .clipped()
        .animation(.snappy(duration: 0.18), value: isRevealed)
    }
}
