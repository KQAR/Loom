import ComposableArchitecture
import SwiftUI

/// The request list's quick filters: every chip laid out flat, in one line, docked
/// along the bottom edge of the request area.
///
/// **Flat, not folded.** An earlier version showed a funnel that opened a popover and
/// only drew the selected chips inline; it was smaller at rest and cost a click plus
/// a mode to change anything, which is the wrong trade for a control whose whole point
/// is that it is faster than the find bar. Every chip is its own state — a tinted
/// capsule is on, a plain one is off — so what is being filtered and what could be
/// filtered are the same surface.
///
/// **Docked, not floating.** As an overlay it covered the last rows of the table and
/// had to be laid out around the clear control's hover growth; as the last row of
/// `MainView.requestArea`'s stack it reserves its own height, the table resizes to it
/// the way it already does for the find bar, and it survives the swap to the empty
/// state — which is exactly when a chip that narrowed the window to nothing has to
/// remain undoable. It sits *below* the cap / dropped banners, which are the table's
/// own safe-area insets: those qualify the rows, this one narrows them.
///
/// **Horizontally scrollable, because eighteen chips are wider than the table's
/// floor.** The strip measures ~740pt laid flat and the request area can be narrower
/// than that (`RequestTable.Column` floors total ~700pt). Truncating would hide chips
/// with nothing saying so; the scroll keeps every one reachable.
struct QuickFilterBar: View {
    @Bindable var store: StoreOf<CaptureFeature>

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: LoomTheme.Space.xxs) {
                Image(systemName: "line.3.horizontal.decrease")
                    .font(.caption)
                    .foregroundStyle(store.quickFilter.isActive ? LoomTheme.Palette.accent : Color.secondary)
                    .help("Quick filters — protocol, HTTP version, content type, status")
                    .accessibilityLabel("Quick filters")

                // Bounded by construction: `QuickFilterChip.all` is 18 long and cannot
                // grow with the capture, which is what makes an eager `ForEach` correct
                // here where the request list itself must never use one.
                ForEach(Array(QuickFilterFacet.allCases.enumerated()), id: \.element) { index, facet in
                    if index > 0 {
                        Divider().frame(height: 12)
                    }
                    ForEach(QuickFilterChip.all.filter { $0.facet == facet }, id: \.self) { chip in
                        chipButton(chip)
                    }
                }

                // Present only while something is on: a permanently visible ✕ on a bar
                // with nothing to clear reads as a control that does nothing.
                if store.quickFilter.isActive {
                    Divider().frame(height: 12)
                    Button {
                        store.send(.quickFilterCleared)
                    } label: {
                        Image(systemName: "xmark.circle.fill").font(.caption)
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help("Clear the quick filters — the sidebar selection and the find bar are left alone")
                    .accessibilityLabel("Clear quick filters")
                }
            }
            .padding(.horizontal, LoomTheme.Space.sm)
            .padding(.vertical, LoomTheme.Space.xxs)
        }
        .scrollIndicators(.never)
        // Height is the strip's; width is the window's. Without this the scroll view
        // would take whatever height it was offered and the bar would eat the table.
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        // `.bar`, the same material the find bar and the cap banner use — this is a
        // window chrome strip, not a floating control, and a third treatment on the
        // same edge would read as a third kind of thing.
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    /// One chip. Tinted when on, quaternary when off; its own tap toggles it, which is
    /// the only gesture the bar has — there is no separate "remove" affordance to keep
    /// in step with the selection.
    private func chipButton(_ chip: QuickFilterChip) -> some View {
        let selected = store.quickFilter.contains(chip)
        return Button {
            store.send(.quickFilterToggled(chip))
        } label: {
            Text(chip.label)
                .font(.caption)
                .foregroundStyle(selected ? LoomTheme.Palette.accent : Color.secondary)
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(
                    Capsule().fill(
                        selected
                            ? AnyShapeStyle(LoomTheme.Palette.accent.opacity(0.15))
                            : LoomTheme.Surface.group
                    )
                )
                .overlay {
                    Capsule().strokeBorder(
                        selected ? LoomTheme.Palette.accent.opacity(0.5) : .clear,
                        lineWidth: 1
                    )
                }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help("\(chip.facet.label): \(chip.label) — filters this window's rows only")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
