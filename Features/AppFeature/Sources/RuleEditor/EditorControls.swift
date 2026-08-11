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

/// A dropdown drawn as its own value plus a chevron — no bezel, no well.
///
/// It went through the system pop-up button (AppKit's own bezel and metrics,
/// visibly foreign beside a `LoomTextField`) and then through the field well,
/// which was consistent but heavy: a menu is not somewhere you type, and giving
/// it the enterable surface said it was. What is left is the value and the
/// affordance — the same restraint the console's `config-row` uses, where a
/// chevron is the whole "there is more behind this" vocabulary — with a hover
/// fill because a control that changes silently is one the eye misses
/// (DESIGN.md § Motion).
///
/// Still a `Menu`, so the popup, keyboard handling and accessibility are AppKit's;
/// only the closed state is Loom's.
struct LoomPicker<Value: Hashable>: View {
    @Binding var selection: Value
    let items: [(value: Value, label: String)]
    /// `nil` hugs the current value; a width pins it, so a row of pickers doesn't
    /// reflow as you change one.
    var width: CGFloat?

    @State private var hovering = false

    private var currentLabel: String {
        items.first { $0.value == selection }?.label ?? ""
    }

    var body: some View {
        Menu {
            ForEach(items, id: \.value) { item in
                Button {
                    selection = item.value
                } label: {
                    // A checkmark only on the selected one — an empty `systemImage`
                    // renders as a missing-symbol placeholder rather than nothing.
                    if item.value == selection { Label(item.label, systemImage: "checkmark") }
                    else { Text(item.label) }
                }
            }
        } label: {
            HStack(spacing: LoomTheme.Space.xxs) {
                Text(currentLabel).font(.body).lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
                // Any slack goes *after* the pair. A width is pinned so the row
                // doesn't reflow as the value changes, not to push the chevron to
                // an edge — a borderless control has no edge to push it to, so the
                // gap just read as two unrelated glyphs.
                if width != nil { Spacer(minLength: 0) }
            }
            .padding(.horizontal, LoomTheme.Space.xxs)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: LoomTheme.Radius.sm)
                    .fill(LoomTheme.Palette.accent.opacity(hovering ? LoomTheme.attentionOpacity : 0))
            )
            .contentShape(Rectangle())
        }
        // **Not `.menuStyle(.borderlessButton)`.** Measured with a probe
        // (screenshot, four combinations): that style re-lays-out a custom label
        // and puts the trailing glyph *before* the text — which is why the chevron
        // kept coming out on the left however the `HStack` was ordered. `.plain`
        // button style with the indicator hidden lays the label out as written.
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize(horizontal: width == nil, vertical: true)
        .frame(width: width)
        .onHover { hovering = $0 }
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

/// A bare SF Symbol button that fills on hover — the design system's "this is
/// clickable" affordance (DESIGN.md § Motion). Used for add and remove.
///
/// Glyph-only for adding, same as the console's cards (`ReverseProxyCard`, and
/// DESIGN.md § Components spells it out there): the section a `plus` sits in
/// already says what is being added, so the word spends width on a fact the
/// position gives — while the tooltip and the accessibility label still say it
/// in words. A bordered `+ Add` button per section also out-weighed the rows it
/// was adding to, which is the other half of why they are gone.
struct GlyphButton: View {
    let systemImage: String
    let help: String
    var tint: Color = LoomTheme.Palette.accent
    /// A disabled glyph stays visible rather than disappearing: a control that
    /// vanishes when it can't act reads as a missing feature.
    var isEnabled: Bool = true
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.body)
                .foregroundStyle(isEnabled ? AnyShapeStyle(tint) : AnyShapeStyle(.tertiary))
                .frame(width: 24, height: 24)
                .background(
                    RoundedRectangle(cornerRadius: LoomTheme.Radius.sm)
                        .fill(tint.opacity(hovering && isEnabled ? LoomTheme.attentionOpacity : 0))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .onHover { hovering = $0 }
        .help(help)
        .accessibilityLabel(help)
    }
}

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
