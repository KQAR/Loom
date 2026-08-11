import SwiftUI

/// The action-segment tab strip. It is the **top edge of the actions card**, not
/// a separate control floating above it: the selected tab and the pane under it
/// are one surface, so the eye reads "this pane belongs to that tab" without
/// having to infer it from proximity.
///
/// Not a `Picker(.segmented)`, for two reasons. A segment here carries a second
/// fact the system control has nowhere to put — whether that segment is
/// *configured*, shown as the accent dot — and the system control is a floating
/// capsule that cannot fuse with the pane below it. The selected-tab treatment
/// is the one DESIGN.md § Components already specifies for the inspector's tab
/// strips: semibold plus a 2pt accent underline, here doubling as the hairline
/// between strip and pane.
struct SegmentBar: View {
    @Binding var selection: ActionSegment
    let active: Set<ActionSegment>

    @State private var hovered: ActionSegment?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 0) {
            ForEach(ActionSegment.allCases) { segment in
                Button { selection = segment } label: {
                    VStack(spacing: 0) {
                        HStack(spacing: LoomTheme.Space.xxs) {
                            Text(segment.label)
                            // Shown on the selected segment too: the underline says
                            // which pane you are looking at, the dot says which panes
                            // will be saved — and the one you are editing is exactly
                            // the pane that must not go quiet about it.
                            Circle()
                                .fill(LoomTheme.Palette.accent)
                                .frame(width: 5, height: 5)
                                .opacity(active.contains(segment) ? 1 : 0)
                        }
                        .font(.callout.weight(selection == segment ? .semibold : .regular))
                        .foregroundStyle(selection == segment ? Color.primary : Color.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, LoomTheme.Space.xs)
                        .background(
                            LoomTheme.Palette.accent
                                .opacity(hovered == segment && selection != segment ? LoomTheme.attentionOpacity : 0)
                        )
                        // Sits on top of the strip's own bottom hairline, so the
                        // selected tab visibly breaks the line into the pane.
                        Rectangle()
                            .fill(selection == segment ? LoomTheme.Palette.accent : Color.clear)
                            .frame(height: 2)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { hovered = $0 ? segment : (hovered == segment ? nil : hovered) }
                .accessibilityAddTraits(selection == segment ? [.isSelected] : [])
                .help(active.contains(segment) ? "\(segment.label) — configured" : segment.label)
            }
        }
        .background(alignment: .bottom) { Divider() }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: selection)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: hovered)
    }
}
