import SwiftUI

/// The inspector's aligned two-column table: a titled Key/Value header, a rule, then
/// the caller's rows.
///
/// A `Grid` rather than a `Table` because it lives inside the inspector's
/// `ScrollView` and each pane shows a small, bounded per-flow set — the key column
/// sizes to its widest entry, the value column takes the rest and wraps.
///
/// Extracted because headers and cookies had each grown their own layout, and the
/// cookie one had drifted into an unaligned stack of pairs. Sharing the scaffolding
/// is what keeps "looks like the headers table" true without anyone having to
/// remember to copy the spacing and typography across.
struct KeyValueGrid<Rows: View>: View {
    var keyTitle = "Key"
    var valueTitle = "Value"
    @ViewBuilder let rows: () -> Rows

    var body: some View {
        Grid(alignment: .leadingFirstTextBaseline,
             horizontalSpacing: LoomTheme.Space.md,
             verticalSpacing: LoomTheme.Space.xs) {
            GridRow {
                Text(keyTitle).gridColumnAlignment(.leading)
                Text(valueTitle)
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)

            Divider().gridCellColumns(2)

            rows()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
