import SwiftUI

struct SegmentBar: View {
    @Binding var selection: ActionSegment
    let active: Set<ActionSegment>

    var body: some View {
        HStack(spacing: 0) {
            ForEach(ActionSegment.allCases) { seg in
                Button { selection = seg } label: {
                    HStack(spacing: 4) {
                        Text(seg.label)
                        if active.contains(seg) {
                            Circle().fill(LoomTheme.Palette.accent).frame(width: 6, height: 6)
                        }
                    }
                    .font(.caption.weight(selection == seg ? .semibold : .regular))
                    .foregroundStyle(selection == seg ? Color.primary : Color.secondary)
                    .padding(.vertical, LoomTheme.Space.xs)
                    .frame(maxWidth: .infinity)
                    .background(
                        selection == seg ? LoomTheme.Palette.accent.opacity(0.15) : Color.clear,
                        in: RoundedRectangle(cornerRadius: LoomTheme.Radius.sm)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .loomSurface(LoomTheme.Surface.group, radius: LoomTheme.Radius.md)
    }
}
