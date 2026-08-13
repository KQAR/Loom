import SwiftUI

/// Cookies as an aligned two-column Name/Value table — the same `KeyValueGrid` the
/// headers pane uses.
///
/// They were previously a stack of loose pairs, so each value started at a different
/// x and the pane read nothing like the Headers tab beside it. Cookies are just as
/// much name/value data, and reading values down a column is the point: spotting
/// which session id changed between two flows.
///
/// `Set-Cookie` attributes (`Path`, `HttpOnly`, `SameSite`, …) stay inside the value
/// cell as a secondary line rather than claiming a third column — only response
/// cookies have them, so a column would be dead space on every request pane, and the
/// attribute string is long enough to squeeze the value it describes.
struct CookiesView: View {
    let cookies: [CookieItem]

    var body: some View {
        if cookies.isEmpty {
            Text("No cookies").foregroundStyle(.secondary)
        } else {
            KeyValueGrid(keyTitle: "Name", valueTitle: "Value") {
                ForEach(cookies) { cookie in
                    GridRow(alignment: .firstTextBaseline) {
                        Text(cookie.name)
                            // Same token as a header name and a query parameter's:
                            // all three are the name half of a name/value pair.
                            .foregroundStyle(LoomTheme.Palette.Syntax.name)
                            .textSelection(.enabled)
                            .font(.callout.monospaced())
                        VStack(alignment: .leading, spacing: 2) {
                            Text(cookie.value)
                                .textSelection(.enabled)
                                .font(.callout.monospaced())
                                .fixedSize(horizontal: false, vertical: true)
                            if !cookie.attributes.isEmpty {
                                Text(cookie.attributes)
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                                    .textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
    }
}
