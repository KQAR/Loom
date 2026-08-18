import LoomSharedModels
import SwiftUI

struct RequestPane: View {
    let flow: Flow
    let original: Flow?

    /// The pane's tabs. `flowSummary` is the odd one out and is named for it:
    /// every other case here is scoped to the *request*, while that one reports
    /// the whole exchange (see `FlowSummary`). It is hosted here rather than
    /// given a pane of its own — a UI decision, recorded in DESIGN.md.
    enum Tab: Hashable { case flowSummary, query, graphQL, raw, headers, cookies, body, diff }
    @State private var tab: Tab = .flowSummary

    /// What the pane derives from the request body/headers, parsed **once** per
    /// render. `tabs` needs it (to decide which tabs exist) and `content` needs it
    /// (to render the active one); as separate computed properties, each render
    /// JSON-deserialized a body of up to `graphQLBodyLimit` twice. That matters on
    /// the streaming path, where an open inspector re-renders every ~100 ms batch
    /// while the selected request is still in flight.
    private struct Derived {
        var cookies: [CookieItem]
        var query: [URLQueryPair]
        var graphQL: GraphQLOperation?
    }

    private static func derive(_ flow: Flow) -> Derived {
        Derived(
            cookies: CookieParsing.requestCookies(flow.request.headers),
            // Parsed here with the rest for the same reason: `tabs` needs the count
            // to decide whether the tab exists and `content` needs the items, and as
            // a computed property each render split the URL twice over.
            query: QueryParsing.items(inURL: flow.request.url),
            // Guard on size before parsing — a large POST would otherwise hang the
            // panel on open.
            graphQL: {
                guard let body = flow.request.body, body.count <= InspectorText.graphQLBodyLimit else { return nil }
                return GraphQLParser.parse(flow.request)
            }()
        )
    }

    private func tabs(_ derived: Derived) -> [InspectorTab<Tab>] {
        var t: [InspectorTab<Tab>] = [InspectorTab("Summary", tab: .flowSummary)]
        // Conditional and counted, the same rule Cookies follows: most requests
        // have no query, and a permanent empty tab is a tab people stop reading.
        if !derived.query.isEmpty {
            t.append(InspectorTab("Query", count: derived.query.count, tab: .query))
        }
        if derived.graphQL != nil { t.append(InspectorTab("GraphQL", tab: .graphQL)) }
        t.append(InspectorTab("Raw", tab: .raw))
        t.append(InspectorTab("Headers", count: flow.request.headers.count, tab: .headers))
        if !derived.cookies.isEmpty {
            t.append(InspectorTab("Cookies", count: derived.cookies.count, tab: .cookies))
        }
        t.append(InspectorTab("Body", tab: .body))
        if original != nil { t.append(InspectorTab("Diff", tab: .diff)) }
        return t
    }

    var body: some View {
        let derived = Self.derive(flow)
        return VStack(spacing: 0) {
            HStack(spacing: LoomTheme.Space.sm) {
                InspectorTabStrip(tabs: tabs(derived), selection: $tab)
                Spacer(minLength: LoomTheme.Space.xs)
                MethodBadge(method: flow.request.method)
            }
            .padding(.horizontal, LoomTheme.Space.md)
            .frame(height: 34)
            Divider()

            content(derived)
                .overlay(alignment: .topTrailing) {
                    if tab == .body, let text = Self.bodyText(flow.request.body) {
                        FloatingCopyButton(text: text)
                    }
                }
        }
        .onChange(of: flow.id) {
            // Reset if the selected tab no longer applies to the new flow.
            if tab == .diff, original == nil { tab = .flowSummary }
            if tab == .cookies, derived.cookies.isEmpty { tab = .flowSummary }
            if tab == .query, derived.query.isEmpty { tab = .flowSummary }
            if tab == .graphQL, derived.graphQL == nil { tab = .flowSummary }
        }
    }

    /// Each tab owns its own scrolling: tabular/tree tabs go through `Scrolled`
    /// (a plain SwiftUI `ScrollView`), while Raw/Body hand large payloads to a
    /// viewport-lazy `NSTextView` (see `RawView`) so a big body never blocks the
    /// main thread on open.
    @ViewBuilder private func content(_ derived: Derived) -> some View {
        switch tab {
        case .flowSummary: Scrolled { FlowSummary(flow: flow) }
        case .query: Scrolled { QueryView(items: derived.query) }
        case .graphQL: Scrolled { GraphQLView(operation: derived.graphQL) }
        case .raw: RawTab(flow: flow, pane: "req", makeText: Self.rawText)
        case .headers: Scrolled { HeadersList(headers: flow.request.headers, trailers: flow.request.trailers) }
        case .cookies: Scrolled { CookiesView(cookies: derived.cookies) }
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
    nonisolated static func rawText(_ flow: Flow) -> String {
        let request = flow.request
        var lines = ["\(request.method) \(request.url)"]
        lines += request.headers.map { "\($0.name): \($0.value)" }
        lines.append("")
        if let body = request.body, let string = String(data: body, encoding: .utf8) {
            lines.append(string)
        }
        // After the body: that is where a trailer section sits on the wire.
        if let trailers = request.trailers, !trailers.isEmpty {
            lines.append("")
            lines += trailers.map { "\($0.name): \($0.value)" }
        }
        return lines.joined(separator: "\n")
    }
}
