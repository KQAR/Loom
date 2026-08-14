import LoomSharedModels
import SwiftUI

/// Headers as an aligned two-column Key/Value table (`KeyValueGrid`, shared with the
/// cookies pane so the two can't drift apart), followed by the trailer section when
/// the message carried one.
///
/// Trailers share this tab rather than getting their own. A tab that is empty for
/// every exchange but gRPC would be a permanent piece of dead chrome, and the thing
/// an operator actually wants — `grpc-status` next to the headers that framed it —
/// is one scroll rather than one more click. The heading only appears when there is
/// a section to head, so an ordinary response looks exactly as it did.
struct HeadersList: View {
    let headers: [HeaderPair]
    /// Nil when the message had no trailer section at all, which is almost every
    /// message. An empty-but-present section is still shown: "the origin sent
    /// trailers and they were empty" is a fact worth being able to see.
    var trailers: [HeaderPair]?

    var body: some View {
        VStack(alignment: .leading, spacing: LoomTheme.Space.md) {
            if headers.isEmpty {
                Text("No headers").foregroundStyle(.secondary)
            } else {
                grid(headers)
            }
            if let trailers {
                Text("Trailers")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                if trailers.isEmpty {
                    Text("Empty trailer section").foregroundStyle(.secondary)
                } else {
                    grid(trailers)
                }
            }
        }
    }

    private func grid(_ pairs: [HeaderPair]) -> some View {
        KeyValueGrid {
            ForEach(pairs.indices, id: \.self) { i in
                GridRow(alignment: .firstTextBaseline) {
                    Text(pairs[i].name)
                        // The same violet the Raw pane tints a header name
                        // with — one fact, one token (DESIGN.md §
                        // inspector-parity). It also gives this grid the thing
                        // it was missing: a scan column that is visibly a
                        // different kind of thing from the values beside it.
                        .foregroundStyle(LoomTheme.Palette.Syntax.name)
                        .textSelection(.enabled)
                    Text(pairs[i].value)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .font(.callout.monospaced())
            }
        }
    }
}
