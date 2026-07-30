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
        }
    }
}
