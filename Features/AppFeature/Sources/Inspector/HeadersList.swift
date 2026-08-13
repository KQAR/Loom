import LoomSharedModels
import SwiftUI

/// Headers as an aligned two-column Key/Value table (`KeyValueGrid`, shared with the
/// cookies pane so the two can't drift apart).
struct HeadersList: View {
    let headers: [HeaderPair]

    var body: some View {
        if headers.isEmpty {
            Text("No headers").foregroundStyle(.secondary)
        } else {
            KeyValueGrid {
                ForEach(headers.indices, id: \.self) { i in
                    GridRow(alignment: .firstTextBaseline) {
                        Text(headers[i].name)
                            // The same violet the Raw pane tints a header name
                            // with — one fact, one token (DESIGN.md §
                            // inspector-parity). It also gives this grid the thing
                            // it was missing: a scan column that is visibly a
                            // different kind of thing from the values beside it.
                            .foregroundStyle(LoomTheme.Palette.Syntax.name)
                            .textSelection(.enabled)
                        Text(headers[i].value)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .font(.callout.monospaced())
                }
            }
        }
    }
}
