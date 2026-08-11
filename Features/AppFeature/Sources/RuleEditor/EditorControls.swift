import SwiftUI

/// The rule editor's control vocabulary.
///
/// The sheet had three different renderings of "a text field" — `.roundedBorder`,
/// `.plain` inside a `loomSurface` well, and the bare default — sometimes two of
/// them on the same row. None was wrong on its own; together they read as three
/// kinds of surface in one sheet, which is the thing DESIGN.md's token rules exist
/// to prevent. So there is one field, one text area, one glyph button and one
/// toggle tint here, and the editor views compose them.
///
/// This is **not** custom-drawing over a system control for decoration's sake
/// (DESIGN.md § Do's and Don'ts): the well + hairline pair is already Loom's
/// `loomField()`, the only addition is that the hairline becomes the accent while
/// the field has focus — accent *is* the focus signal in this design system, and
/// `.plain` fields otherwise show no focus at all, which is what made the sheet
/// hard to navigate from the keyboard.

// MARK: - Fields

/// One-line text input. `mono` for anything that comes off the wire — a URL
/// pattern, a header name, a host glob (DESIGN.md § Typography).
///
/// `.body`, not `.callout`: this is text the human *authors*, so it reads at the
/// same size as body copy everywhere else. `.callout` is for metadata about a
/// control, which is what the label above it is.
struct LoomTextField: View {
    @Binding var text: String
    var prompt: String = ""
    var mono: Bool = false

    @FocusState private var focused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TextField("", text: $text, prompt: prompt.isEmpty ? nil : Text(prompt))
            .textFieldStyle(.plain)
            .font(mono ? .body.monospaced() : .body)
            .focused($focused)
            .padding(.horizontal, LoomTheme.Control.fieldPaddingH)
            .padding(.vertical, LoomTheme.Control.fieldPaddingV)
            .loomFocusWell(focused: focused, reduceMotion: reduceMotion)
    }
}

/// Multi-line input — headers, bodies, base64. Same well as `LoomTextField` so a
/// one-line field and the box under it read as the same kind of surface.
struct LoomTextArea: View {
    @Binding var text: String
    var minHeight: CGFloat = 96

    @FocusState private var focused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TextEditor(text: $text)
            .font(.body.monospaced())
            .focused($focused)
            .scrollContentBackground(.hidden)
            .frame(minHeight: minHeight)
            .padding(.horizontal, LoomTheme.Space.xxs)
            .padding(.vertical, LoomTheme.Space.xxs)
            .loomFocusWell(focused: focused, reduceMotion: reduceMotion)
    }
}

extension View {
    /// `loomField()` whose hairline turns accent while focused. Separate from
    /// `loomField()` itself because most wells in the app aren't focusable.
    func loomFocusWell(focused: Bool, reduceMotion: Bool) -> some View {
        background(LoomTheme.Surface.field, in: RoundedRectangle(cornerRadius: LoomTheme.Radius.sm))
            .overlay {
                RoundedRectangle(cornerRadius: LoomTheme.Radius.sm)
                    .strokeBorder(
                        focused ? AnyShapeStyle(LoomTheme.Palette.accent) : AnyShapeStyle(.quaternary),
                        lineWidth: focused ? 1.5 : 1
                    )
            }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: focused)
    }

    /// Every switch and checkbox in the editor carries Loom's accent, not the
    /// user's system one — AppKit controls default to the system accent and
    /// DESIGN.md § Colors says to tint them explicitly.
    func loomToggle() -> some View {
        tint(LoomTheme.Palette.accent)
    }

    /// All buttons are capsules (DESIGN.md § Shapes).
    func loomCapsuleButton() -> some View {
        buttonBorderShape(.capsule)
    }
}

/// A dropdown with its name beside it — the shape every labelled control in the
/// sheet already has (`LabeledField` stacks, this one is inline because a type or
/// a source is a short word and a stacked label would cost a row for it).
struct LoomLabeledPicker<Value: Hashable>: View {
    let label: String
    @Binding var selection: Value
    let items: [(value: Value, label: String)]
    var width: CGFloat?

    var body: some View {
        HStack(spacing: LoomTheme.Space.xs) {
            Text(label).font(.callout).foregroundStyle(.secondary)
            LoomPicker(selection: $selection, items: items, width: width)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(label)
    }
}

// MARK: - Labels & hints

/// A field's name: `.callout` secondary, one step under the `.body` the field
/// itself is set in. Explanatory copy (`EditorHint`) is the same size and one ink
/// step down — DESIGN.md § Typography, hierarchy by ink rather than by size, so
/// the sheet has two text sizes rather than four.
struct LabeledField<Content: View>: View {
    let label: String
    @ViewBuilder let content: Content

    init(_ label: String, @ViewBuilder content: () -> Content) {
        self.label = label
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: LoomTheme.Space.xxs) {
            Text(label).font(.callout).foregroundStyle(.secondary)
            content
        }
    }
}

/// Explanatory copy under a control: what it does, or why it is inert right now.
struct EditorHint: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Buttons

/// A text button sized like a field.
///
/// `.bordered` + `.controlSize(.small)` gave AppKit's own metrics, which sit a few
/// points shorter than a `LoomTextField` — fine on its own, visibly off when the
/// two share a row (the "Choose…" beside a file path). Deriving the height from
/// the same font and the same `Control` padding keeps them equal at any Dynamic
/// Type size, which a hardcoded `frame(height:)` would not.
struct LoomButton: View {
    let title: String
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.body)
                .padding(.horizontal, LoomTheme.Space.sm)
                .padding(.vertical, LoomTheme.Control.fieldPaddingV)
                .background(
                    Capsule().fill(hovering ? AnyShapeStyle(LoomTheme.Palette.accent.opacity(0.18)) : AnyShapeStyle(.quaternary))
                )
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// A compact on/off chip carrying a short glyph-as-text label (`.*`, `=`, `Aa`).
/// It is a toggle, not a button, so it states its own state: accent text on an
/// accent wash when on, secondary and unfilled when off, with a hover fill in
/// between so it reads as clickable before it is clicked.
struct ChipToggle: View {
    let label: String
    let isOn: Bool
    let help: String
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.callout.monospaced().weight(.bold))
                .foregroundStyle(isOn ? LoomTheme.Palette.accent : Color.secondary)
                .frame(width: 28, height: 26)
                .background(
                    RoundedRectangle(cornerRadius: LoomTheme.Radius.sm)
                        .fill(LoomTheme.Palette.accent.opacity(fillOpacity))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
        .accessibilityLabel(help)
        .accessibilityAddTraits(isOn ? [.isSelected] : [])
    }

    private var fillOpacity: CGFloat {
        if isOn { return 0.15 }
        return hovering ? LoomTheme.attentionOpacity : 0
    }
}
