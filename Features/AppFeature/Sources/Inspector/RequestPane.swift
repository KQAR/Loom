import AppKit
import LoomSharedModels
import SwiftUI

struct RequestPane: View {
    let flow: Flow
    let original: Flow?

    enum Tab: Hashable { case summary, graphQL, raw, headers, cookies, body, diff }
    @State private var tab: Tab = .summary

    private var cookies: [CookieItem] { CookieParsing.requestCookies(flow.request.headers) }
    private var graphQL: GraphQLOperation? {
        // `GraphQLParser.parse` JSON-deserializes the whole body; `tabs` reads
        // this on every render (to decide the GraphQL tab), so guard on size
        // first — a large POST would otherwise hang the panel on open.
        guard let body = flow.request.body, body.count <= InspectorText.graphQLBodyLimit else { return nil }
        return GraphQLParser.parse(flow.request)
    }

    private var tabs: [(String, Tab)] {
        var t: [(String, Tab)] = [("Summary", .summary)]
        if graphQL != nil { t.append(("GraphQL", .graphQL)) }
        t.append(("Raw", .raw))
        t.append(("Headers(\(flow.request.headers.count))", .headers))
        if !cookies.isEmpty { t.append(("Cookies(\(cookies.count))", .cookies)) }
        t.append(("Body", .body))
        if original != nil { t.append(("Diff", .diff)) }
        return t
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: LoomTheme.Space.sm) {
                InspectorTabStrip(tabs: tabs, selection: $tab)
                Spacer(minLength: LoomTheme.Space.xs)
                MethodBadge(method: flow.request.method)
            }
            .padding(.horizontal, LoomTheme.Space.md)
            .frame(height: 34)
            Divider()

            CopyableURLBar(url: flow.request.url)
            Divider()

            content
                .overlay(alignment: .topTrailing) {
                    if tab == .body, let text = Self.bodyText(flow.request.body) {
                        FloatingCopyButton(text: text)
                    }
                }
        }
        .onChange(of: flow.id) {
            // Reset if the selected tab no longer applies to the new flow.
            if tab == .diff, original == nil { tab = .summary }
            if tab == .cookies, cookies.isEmpty { tab = .summary }
            if tab == .graphQL, graphQL == nil { tab = .summary }
        }
    }

    /// Each tab owns its own scrolling: tabular/tree tabs go through `Scrolled`
    /// (a plain SwiftUI `ScrollView`), while Raw/Body hand large payloads to a
    /// viewport-lazy `NSTextView` (see `RawView`) so a big body never blocks the
    /// main thread on open.
    @ViewBuilder private var content: some View {
        switch tab {
        case .summary: Scrolled { SummaryTable(flow: flow) }
        case .graphQL: Scrolled { GraphQLView(operation: graphQL) }
        case .raw: RawView(text: Self.rawText(flow), identity: "req-raw:\(flow.id)")
        case .headers: Scrolled { HeadersList(headers: flow.request.headers) }
        case .cookies: Scrolled { CookiesView(cookies: cookies) }
        case .body: BodyView(data: flow.request.body, identity: "req-body:\(flow.id)", fullBodyBytes: flow.request.fullBodyBytes)
        case .diff: Scrolled { DiffView(original: original, replayed: flow) }
        }
    }

    /// Body as a UTF-8 string, or nil when empty/non-text (no copy button then).
    static func bodyText(_ data: Data?) -> String? {
        guard let data, !data.isEmpty, let text = String(data: data, encoding: .utf8), !text.isEmpty
        else { return nil }
        return text
    }

    /// The captured request as raw text: request line · headers · blank · body.
    static func rawText(_ flow: Flow) -> String {
        let request = flow.request
        var lines = ["\(request.method) \(request.url)"]
        lines += request.headers.map { "\($0.name): \($0.value)" }
        lines.append("")
        if let body = request.body, let string = String(data: body, encoding: .utf8) {
            lines.append(string)
        }
        return lines.joined(separator: "\n")
    }
}
