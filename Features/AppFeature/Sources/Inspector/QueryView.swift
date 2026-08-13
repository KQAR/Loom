import SwiftUI

/// The URL's query parameters as an aligned two-column table — the same
/// `KeyValueGrid` the Headers and Cookies panes use, so the three read alike.
///
/// It exists because the URL bar is the only other place these appear, and there
/// they are one unbroken percent-encoded line: a request with eight parameters is
/// a line nobody reads, and the one parameter someone is checking is in the
/// middle of it. Decoded and stacked, that is a glance.
struct QueryView: View {
    let items: [URLQueryPair]

    var body: some View {
        if items.isEmpty {
            Text("No query parameters").foregroundStyle(.secondary)
        } else {
            KeyValueGrid(keyTitle: "Name", valueTitle: "Value") {
                ForEach(items) { item in
                    GridRow(alignment: .firstTextBaseline) {
                        Text(item.name)
                            .foregroundStyle(LoomTheme.Palette.Syntax.name)
                            .textSelection(.enabled)
                        // A flag (`?debug`, no `=`) is not an empty value, and the
                        // two mean different things to plenty of servers — so the
                        // absence is stated rather than drawn as a blank cell,
                        // which would read as "the value is empty".
                        Text(item.isFlag ? "—" : item.value)
                            .foregroundStyle(item.isFlag ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.primary))
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .font(.callout.monospaced())
                }
            }
        }
    }
}
