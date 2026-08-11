import SwiftUI

/// Which part of a message a pane is editing. One enum for both sides; the
/// labels differ, the structure doesn't.
enum MessagePart: Hashable, CaseIterable {
    case line, headers, body

    func label(request: Bool) -> String {
        switch self {
        case .line: return request ? "Request line" : "Response line"
        case .headers: return "Headers"
        case .body: return "Body"
        }
    }
}

/// A scaled-down `SegmentBar` for picking a sub-part inside an action pane.
///
/// Same vocabulary as the outer tab strip — label, accent dot for "this one is
/// configured", accent underline for "this one is selected" — at caption size, so
/// the nesting reads as nesting rather than as two competing tab strips.
///
/// **The dot shows on the selected segment too.** It answers a different question
/// from the underline: the underline says *what you are looking at*, the dot says
/// *what will be saved*. Hiding it on the selected one made the pane you are
/// editing the only one that wouldn't tell you whether it was on.
struct SubSegmentBar<Value: Hashable>: View {
    @Binding var selection: Value
    let items: [(value: Value, label: String)]
    let active: Set<Value>

    @State private var hovered: Value?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 0) {
            ForEach(items, id: \.value) { item in
                Button { selection = item.value } label: {
                    HStack(spacing: LoomTheme.Space.xxs) {
                        Text(item.label)
                        Circle()
                            .fill(LoomTheme.Palette.accent)
                            .frame(width: 4, height: 4)
                            .opacity(active.contains(item.value) ? 1 : 0)
                    }
                    .font(.caption.weight(selection == item.value ? .semibold : .regular))
                    .foregroundStyle(selection == item.value ? Color.primary : Color.secondary)
                    // Intrinsic width, not an equal share of the pane: three
                    // stretched thirds read as a control that owns the row, which
                    // is what the *outer* tab strip is. This one labels a sub-part,
                    // so it hugs its labels and sits at the margin like every other
                    // label in the sheet.
                    .padding(.horizontal, LoomTheme.Space.sm)
                    .padding(.vertical, LoomTheme.Space.xxs)
                    .background(
                        LoomTheme.Palette.accent
                            .opacity(hovered == item.value && selection != item.value ? LoomTheme.attentionOpacity : 0)
                    )
                    // The underline is an **overlay**, not a sibling in a VStack: a
                    // `Rectangle` is greedy, so as a sibling it expanded to the
                    // available width and dragged the whole segment out with it —
                    // which is why left-aligning the labels alone did nothing.
                    // An overlay is sized by what it covers.
                    .overlay(alignment: .bottom) {
                        Rectangle()
                            .fill(selection == item.value ? LoomTheme.Palette.accent : Color.clear)
                            .frame(height: 1.5)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { hovered = $0 ? item.value : (hovered == item.value ? nil : hovered) }
                .accessibilityAddTraits(selection == item.value ? [.isSelected] : [])
                .help(active.contains(item.value) ? "\(item.label) — edited" : item.label)
            }
            // The bar still spans the pane so its hairline does; only the segments
            // are left-aligned within it.
            Spacer(minLength: 0)
        }
        .background(alignment: .bottom) { Divider() }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: selection)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: hovered)
    }
}
