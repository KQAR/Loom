import LoomSharedModels
import SwiftUI

/// Cookies as an aligned two-column Name/Value pane — the same `KeyValuePane` the
/// headers and query panes use, so the three read alike.
///
/// `Set-Cookie` attributes (`Path`, `HttpOnly`, `SameSite`, …) stay in the value
/// column as a dimmer second line rather than claiming a third column — only response
/// cookies have them, so a column would be dead space on every request pane, and the
/// attribute string is long enough to squeeze the value it describes.
struct CookiesView: View {
    let cookies: [CookieItem]
    /// In-pane find. Matching rows are washed; Enter / chevrons step `1/N` and
    /// scroll the current one into view.
    var find: InspectorFind = InspectorFind()

    var body: some View {
        if cookies.isEmpty {
            Scrolled { Text("No cookies").foregroundStyle(.secondary) }
        } else {
            KeyValuePane(lines: lines, find: find)
        }
    }

    private var lines: [KeyValueLine] {
        [.captions(key: "Name", value: "Value")]
            + cookies.map { .pair(name: $0.name, value: $0.value, secondary: $0.attributes) }
    }

    /// `name=value` lines, attributes appended when present. What Copy writes.
    static func copyText(_ cookies: [CookieItem]) -> String {
        cookies.map { cookie in
            cookie.attributes.isEmpty
                ? "\(cookie.name)=\(cookie.value)"
                : "\(cookie.name)=\(cookie.value); \(cookie.attributes)"
        }.joined(separator: "\n")
    }
}
