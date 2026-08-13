import SwiftUI

/// One tab of an inspector pane: a title, and optionally how many things are
/// behind it.
///
/// The count is a **field, not part of the title string**. It used to be
/// interpolated in (`"Headers(\(n))"`), which meant the strip could not style it
/// apart from the label, and the only way to get it back would be to parse the
/// text it had just been handed.
struct InspectorTab<Tab: Hashable>: Identifiable {
    let title: String
    /// Nil for a tab whose contents aren't a countable list (Summary, Raw, Body).
    let count: Int?
    let tab: Tab

    init(_ title: String, count: Int? = nil, tab: Tab) {
        self.title = title
        self.count = count
        self.tab = tab
    }

    var id: Tab { tab }
}

struct InspectorTabStrip<Tab: Hashable>: View {
    let tabs: [InspectorTab<Tab>]
    @Binding var selection: Tab

    var body: some View {
        HStack(spacing: LoomTheme.Space.md) {
            ForEach(tabs) { entry in
                Button {
                    selection = entry.tab
                } label: {
                    HStack(spacing: LoomTheme.Space.xxs) {
                        Text(entry.title)
                            .foregroundStyle(selection == entry.tab ? Color.primary : Color.secondary)
                        if let count = entry.count { countBadge(count) }
                    }
                    .font(.callout.weight(selection == entry.tab ? .semibold : .regular))
                    .padding(.vertical, LoomTheme.Space.xs)
                    .overlay(alignment: .bottom) {
                        Rectangle()
                            .fill(selection == entry.tab ? LoomTheme.Palette.accent : .clear)
                            .frame(height: 2)
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }

    /// The count, marked by a **fill rather than a hue**.
    ///
    /// It answers a different question from the title — *is there anything in
    /// here, and how much* — and that is what someone scans this strip for; before
    /// this it was interpolated into the label as `Headers(8)` and inherited
    /// `.secondary`, so it disappeared into the word.
    ///
    /// Not a colour, though, and that is the constraint rather than a preference:
    /// every hue in this app is already a status — green 2xx, yellow 3xx and
    /// faults, red errors, and the accent for interactivity, which the *selected
    /// tab's own underline* is drawn in. Spending one on a count is how colour
    /// stops meaning anything (DESIGN.md § Colors), and the accent specifically
    /// would have put the same blue on the count and on the underline of the tab
    /// carrying it.
    ///
    /// So the marker is a neutral capsule at `attentionOpacity`, with the digits
    /// left in the label's own ink. It reads as "there are things here" without
    /// claiming any of them is good or bad. The sidebar's bare-digits rule
    /// (`{components.sidebar-counts}`) does not apply: there, every row has a
    /// count and a column of capsules would be noise; here a strip has two or
    /// three.
    private func countBadge(_ count: Int) -> some View {
        Text("\(count)")
            .monospacedDigit()
            .foregroundStyle(.secondary)
            .padding(.horizontal, LoomTheme.Space.xxs)
            .padding(.vertical, 1)
            .background(
                RoundedRectangle(cornerRadius: LoomTheme.Radius.sm, style: .continuous)
                    .fill(Color.secondary.opacity(LoomTheme.attentionOpacity))
            )
    }
}
