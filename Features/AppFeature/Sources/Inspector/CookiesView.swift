import LoomSharedModels
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
    /// In-pane find. Matching rows are washed; Enter / chevrons step `1/N` and
    /// scroll the current one into the enclosing `Scrolled` viewport.
    var find: InspectorFind = InspectorFind()

    var body: some View {
        if cookies.isEmpty {
            Text("No cookies").foregroundStyle(.secondary)
        } else {
            // One scan per render — see the same note in `HeadersList`.
            let matches = matchIndices
            let matched = Set(matches)
            let current = matches.indices.contains(find.currentIndex) ? matches[find.currentIndex] : nil
            ScrollViewReader { proxy in
                KeyValueGrid(keyTitle: "Name", valueTitle: "Value") {
                    ForEach(cookies.indices, id: \.self) { i in
                        let cookie = cookies[i]
                        let isMatch = matched.contains(i)
                        GridRow(alignment: .firstTextBaseline) {
                            Text(cookie.name)
                                // Same token as a header name and a query parameter's:
                                // all three are the name half of a name/value pair.
                                .foregroundStyle(LoomTheme.Palette.Syntax.name)
                                .textSelection(.enabled)
                                .font(.callout.monospaced())
                                .background { KeyValueFindWash.fill(isMatch: isMatch, isCurrent: current == i) }
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
                            .background { KeyValueFindWash.fill(isMatch: isMatch, isCurrent: current == i) }
                        }
                        .id(i)
                    }
                }
                .preference(
                    key: InspectorFindReportKey.self,
                    value: find.isActive ? InspectorFindReport(matchCount: matches.count) : .empty
                )
                .task(id: current) {
                    guard let current else { return }
                    await Task.yield()
                    proxy.scrollTo(current, anchor: .center)
                }
            }
        }
    }

    /// `name=value` lines, attributes appended when present. What Copy writes.
    static func copyText(_ cookies: [CookieItem]) -> String {
        cookies.map { cookie in
            cookie.attributes.isEmpty
                ? "\(cookie.name)=\(cookie.value)"
                : "\(cookie.name)=\(cookie.value); \(cookie.attributes)"
        }.joined(separator: "\n")
    }

    private var matchIndices: [Int] {
        guard find.isActive else { return [] }
        let matcher = NeedleMatcher(find.trimmed)
        return cookies.indices.filter {
            InspectorFindMatch.rowMatches(Self.fields(cookies[$0]), matcher: matcher)
        }
    }

    private static func fields(_ cookie: CookieItem) -> [String] {
        [cookie.name, cookie.value, cookie.attributes]
    }
}
