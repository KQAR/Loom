import SwiftUI

/// The URL's query parameters as an aligned two-column pane — the same
/// `KeyValuePane` the Headers and Cookies panes use, so the three read alike.
///
/// It exists because the URL bar is the only other place these appear, and there
/// they are one unbroken percent-encoded line: a request with eight parameters is
/// a line nobody reads, and the one parameter someone is checking is in the
/// middle of it. Decoded and stacked, that is a glance.
struct QueryView: View {
    let items: [URLQueryPair]

    var body: some View {
        if items.isEmpty {
            Scrolled { Text("No query parameters").foregroundStyle(.secondary) }
        } else {
            KeyValuePane(lines: lines)
        }
    }

    private var lines: [KeyValueLine] {
        // A flag (`?debug`, no `=`) is not an empty value, and the two mean different
        // things to plenty of servers — so the absence is stated rather than drawn as
        // a blank cell, which would read as "the value is empty", and it is dimmed
        // because it is Loom's word, not the wire's.
        [.captions(key: "Name", value: "Value")]
            + items.map {
                .pair(name: $0.name, value: $0.isFlag ? "—" : $0.value, dimValue: $0.isFlag)
            }
    }
}
