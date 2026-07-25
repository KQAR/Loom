import LoomSharedModels
import SwiftUI

/// Headers as an aligned two-column Key/Value table. A `Grid` (not a `Table`)
/// because it lives inside the inspector's `ScrollView` and headers are a small,
/// bounded per-flow set — the key column sizes to its widest name, the value
/// column takes the rest and wraps.
struct HeadersList: View {
    let headers: [HeaderPair]

    var body: some View {
        if headers.isEmpty {
            Text("No headers").foregroundStyle(.secondary)
        } else {
            Grid(alignment: .leadingFirstTextBaseline,
                 horizontalSpacing: LoomTheme.Space.md,
                 verticalSpacing: LoomTheme.Space.xs) {
                GridRow {
                    Text("Key").gridColumnAlignment(.leading)
                    Text("Value")
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

                Divider().gridCellColumns(2)

                ForEach(headers.indices, id: \.self) { i in
                    GridRow(alignment: .firstTextBaseline) {
                        Text(headers[i].name)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                        Text(headers[i].value)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .font(.callout.monospaced())
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
