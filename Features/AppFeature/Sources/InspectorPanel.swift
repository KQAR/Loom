import AppKit
import LoomSharedModels
import SwiftUI

/// Size guards for the detail panes. A flow's body can be up to
/// `StreamRelay.captureCap` (5 MB); handing that to the render path unbounded
/// beachballs the panel on open.
enum InspectorText {
    /// Byte size above which a raw/body pane switches from the line-numbered
    /// SwiftUI `Text` (which lays its whole string out synchronously on the
    /// main thread) to a viewport-lazy `NSTextView` (`CodeTextView`), which
    /// only lays out the visible region — so the full body renders without
    /// stalling the UI on open.
    static let plainTextThreshold = 100_000
    /// A GraphQL request body is never this large. Above it we skip the full
    /// JSON deserialize `GraphQLParser` does, so opening a big POST's detail
    /// doesn't hang while building the tab strip.
    static let graphQLBodyLimit = 512_000
}

/// Bottom pane of the main window. Layout referenced from Proxyman (not copied):
/// a left/right split — **Request** on the left, **Response** on the right — each
/// with its own tab strip. Fields are limited to what Loom actually captures.
struct InspectorPanel: View {
    let flow: Flow
    let original: Flow?
    let onClose: () -> Void

    var body: some View {
        HSplitView {
            RequestPane(flow: flow, original: original)
                .frame(minWidth: 300)
            ResponsePane(flow: flow, onClose: onClose)
                .frame(minWidth: 300)
        }
    }
}

// MARK: - Request (left)

private struct RequestPane: View {
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
        case .body: BodyView(data: flow.request.body, identity: "req-body:\(flow.id)")
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

// MARK: - Response (right)

private struct ResponsePane: View {
    let flow: Flow
    let onClose: () -> Void

    enum Tab: Hashable { case messages, raw, headers, cookies, body }
    @State private var tab: Tab = .raw

    private var cookies: [CookieItem] {
        CookieParsing.responseCookies(flow.response?.headers ?? [])
    }

    private var messages: [WebSocketMessage] { flow.webSocketMessages ?? [] }

    private var tabs: [(String, Tab)] {
        if flow.isWebSocket {
            // A WebSocket flow's payload is its frames, not a body.
            return [("Messages(\(messages.count))", .messages), ("Headers(\(flow.response?.headers.count ?? 0))", .headers)]
        }
        var t: [(String, Tab)] = [
            ("Raw", .raw),
            ("Headers(\(flow.response?.headers.count ?? 0))", .headers),
        ]
        if !cookies.isEmpty { t.append(("Cookies(\(cookies.count))", .cookies)) }
        t.append(("Body", .body))
        return t
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: LoomTheme.Space.sm) {
                InspectorTabStrip(tabs: tabs, selection: $tab)
                Spacer(minLength: LoomTheme.Space.xs)
                if let code = flow.statusCode {
                    StatusBadge(code: code)
                } else if flow.error != nil {
                    StatusBadge(code: nil)
                }
                Button(action: onClose) {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .help("Close detail")
            }
            .padding(.horizontal, LoomTheme.Space.md)
            .frame(height: 34)
            Divider()

            // Rule audit trail: on the Raw tab, say plainly that this response
            // was shaped by rules (mocked/rewritten/blocked/delayed) and by which.
            if tab == .raw, let applied = flow.appliedRules, !applied.isEmpty {
                HStack(spacing: LoomTheme.Space.xs) {
                    Image(systemName: "wand.and.stars")
                        .font(.caption)
                    Text("Modified by \(applied.count == 1 ? "rule" : "rules"): \(applied.map(\.name).joined(separator: ", "))")
                        .font(.caption)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                    Spacer(minLength: 0)
                }
                .foregroundStyle(Color.accentColor)
                .padding(.horizontal, LoomTheme.Space.md)
                .padding(.vertical, LoomTheme.Space.xs)
                .background(Color.accentColor.opacity(LoomTheme.attentionOpacity))
                Divider()
            }

            content
                .overlay(alignment: .topTrailing) {
                    if tab == .body, let text = RequestPane.bodyText(flow.response?.body) {
                        FloatingCopyButton(text: text)
                    }
                }
        }
        .onAppear { if flow.isWebSocket { tab = .messages } }
        .onChange(of: flow.id) {
            if flow.isWebSocket { tab = .messages }
            else if tab == .messages { tab = .raw }
            else if tab == .cookies, cookies.isEmpty { tab = .raw }
        }
    }

    /// See `RequestPane.content`: each tab scrolls itself; Raw/Body route large
    /// payloads to the viewport-lazy `NSTextView`.
    @ViewBuilder private var content: some View {
        if tab == .messages {
            Scrolled { WebSocketMessagesView(messages: messages) }
        } else if let response = flow.response {
            switch tab {
            case .messages: EmptyView()
            case .raw: RawView(text: Self.rawText(flow), identity: "resp-raw:\(flow.id)")
            case .headers: Scrolled { HeadersList(headers: response.headers) }
            case .cookies: Scrolled { CookiesView(cookies: cookies) }
            case .body: BodyView(data: response.body, identity: "resp-body:\(flow.id)")
            }
        } else if let error = flow.error {
            Scrolled { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red) }
        } else {
            Scrolled { Text("Waiting for response…").foregroundStyle(.secondary) }
        }
    }

    static func rawText(_ flow: Flow) -> String {
        guard let response = flow.response else { return "" }
        var lines = ["HTTP \(response.statusCode)"]
        lines += response.headers.map { "\($0.name): \($0.value)" }
        lines.append("")
        if let body = response.body, let string = String(data: body, encoding: .utf8) {
            lines.append(string)
        }
        return lines.joined(separator: "\n")
    }
}

// MARK: - Shared pieces

private struct InspectorTabStrip<Tab: Hashable>: View {
    let tabs: [(String, Tab)]
    @Binding var selection: Tab

    var body: some View {
        HStack(spacing: LoomTheme.Space.md) {
            ForEach(tabs, id: \.1) { title, tab in
                Button {
                    selection = tab
                } label: {
                    Text(title)
                        .font(.callout.weight(selection == tab ? .semibold : .regular))
                        .foregroundStyle(selection == tab ? Color.primary : Color.secondary)
                        .padding(.vertical, LoomTheme.Space.xs)
                        .overlay(alignment: .bottom) {
                            Rectangle()
                                .fill(selection == tab ? Color.accentColor : .clear)
                                .frame(height: 2)
                        }
                }
                .buttonStyle(.plain)
            }
        }
    }
}

private struct MethodBadge: View {
    let method: String
    var body: some View {
        CapsuleBadge(text: method, font: .caption.monospaced().weight(.semibold), hPadding: 7)
    }
}

private struct StatusBadge: View {
    let code: Int?
    var body: some View {
        let color = code.map { LoomTheme.statusColor(status: $0, isError: false) } ?? .red
        CapsuleBadge(
            text: code.map(String.init) ?? "ERR",
            font: .caption.monospacedDigit().weight(.semibold),
            tint: color, hPadding: 7
        )
    }
}

private struct CopyableURLBar: View {
    let url: String
    var body: some View {
        HStack(spacing: LoomTheme.Space.xs) {
            Text(url)
                .font(.callout.monospaced())
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
            Spacer(minLength: LoomTheme.Space.xs)
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(url, forType: .string)
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .help("Copy URL")
        }
        .padding(.horizontal, LoomTheme.Space.md)
        .padding(.vertical, LoomTheme.Space.xs)
    }
}

private struct SummaryTable: View {
    let flow: Flow
    var body: some View {
        VStack(alignment: .leading, spacing: LoomTheme.Space.sm) {
            row("Status", statusText)
            row("Method", flow.request.method)
            if let code = flow.statusCode { row("Code", "\(code)") }
            if let host = flow.host { row("Host", host) }
            if let ms = flow.durationMS { row("Duration", "\(ms) ms") }
            row("Started", flow.startedAt.formatted(date: .abbreviated, time: .standard))
            if flow.replayedFrom != nil { row("Origin", "Replayed") }
            if let applied = flow.appliedRules, !applied.isEmpty {
                row("Rules", applied.map(\.name).joined(separator: ", "), color: .accentColor)
            }
            if let error = flow.error { row("Error", error, color: .red) }
        }
        .font(.callout)
    }

    private var statusText: String {
        if flow.error != nil { return "Failed" }
        return flow.response != nil ? "Completed" : "In progress"
    }

    private func row(_ label: String, _ value: String, color: Color = .primary) -> some View {
        HStack(alignment: .top, spacing: LoomTheme.Space.md) {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 110, alignment: .leading)
            Text(value)
                .foregroundStyle(color)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
    }
}

/// Floating copy button pinned to the top-right of a body pane; copies the whole
/// body and briefly flips to a checkmark for feedback.
private struct FloatingCopyButton: View {
    let text: String
    @State private var copied = false

    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            copied = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
        } label: {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                .font(.callout)
                .foregroundStyle(copied ? Color.accentColor : .secondary)
                .padding(6)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: LoomTheme.Radius.sm))
                .overlay(
                    RoundedRectangle(cornerRadius: LoomTheme.Radius.sm)
                        .stroke(.quaternary, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .help("Copy body")
        .padding(LoomTheme.Space.sm)
    }
}

// MARK: - Cookies

struct CookieItem: Identifiable, Equatable {
    let id = UUID()
    let name: String
    let value: String
    /// Set-Cookie attributes (Path, HttpOnly, …), joined for display; empty for request cookies.
    var attributes: String = ""
}

enum CookieParsing {
    /// Request cookies come from `Cookie: a=1; b=2` header(s).
    static func requestCookies(_ headers: [HeaderPair]) -> [CookieItem] {
        headers
            .filter { $0.name.lowercased() == "cookie" }
            .flatMap { $0.value.components(separatedBy: ";") }
            .compactMap { pair in
                let trimmed = pair.trimmingCharacters(in: .whitespaces)
                guard let eq = trimmed.firstIndex(of: "="), eq != trimmed.startIndex else { return nil }
                return CookieItem(
                    name: String(trimmed[..<eq]),
                    value: String(trimmed[trimmed.index(after: eq)...])
                )
            }
    }

    /// Response cookies come from `Set-Cookie` header(s); the first `k=v` is the
    /// cookie, the rest are attributes.
    static func responseCookies(_ headers: [HeaderPair]) -> [CookieItem] {
        headers
            .filter { $0.name.lowercased() == "set-cookie" }
            .compactMap { header in
                let parts = header.value.components(separatedBy: ";")
                guard let first = parts.first?.trimmingCharacters(in: .whitespaces),
                      let eq = first.firstIndex(of: "="), eq != first.startIndex else { return nil }
                let attrs = parts.dropFirst()
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                    .joined(separator: " · ")
                return CookieItem(
                    name: String(first[..<eq]),
                    value: String(first[first.index(after: eq)...]),
                    attributes: attrs
                )
            }
    }
}

private struct CookiesView: View {
    let cookies: [CookieItem]
    var body: some View {
        if cookies.isEmpty {
            Text("No cookies").foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: LoomTheme.Space.sm) {
                ForEach(cookies) { cookie in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(alignment: .top, spacing: LoomTheme.Space.xs) {
                            Text(cookie.name)
                                .foregroundStyle(.secondary)
                            Text(cookie.value)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .font(.callout.monospaced())
                        if !cookie.attributes.isEmpty {
                            Text(cookie.attributes)
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
            }
        }
    }
}

/// GraphQL view: operation label, the query (monospaced), and pretty variables.
private struct GraphQLView: View {
    let operation: GraphQLOperation?

    var body: some View {
        if let operation {
            VStack(alignment: .leading, spacing: LoomTheme.Space.sm) {
                HStack(spacing: LoomTheme.Space.xs) {
                    CapsuleBadge(text: operation.kind.rawValue)
                    if let name = operation.operationName, !name.isEmpty {
                        Text(name).font(.callout.weight(.semibold))
                    }
                }
                Text("Query").font(.caption).foregroundStyle(.secondary)
                Text(operation.query)
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let variables = operation.variablesJSON {
                    Text("Variables").font(.caption).foregroundStyle(.secondary)
                    if let json = JSONValue.parse(Data(variables.utf8)), json.isContainer {
                        JSONView(value: json)
                    } else {
                        Text(variables).font(.callout.monospaced()).textSelection(.enabled)
                    }
                }
            }
        } else {
            Text("Not a GraphQL request").foregroundStyle(.secondary)
        }
    }
}

/// WebSocket frame log: one row per message, ↑ client→server / ↓ server→client,
/// with a kind badge and the text (or a byte count for binary/control frames).
private struct WebSocketMessagesView: View {
    let messages: [WebSocketMessage]

    var body: some View {
        if messages.isEmpty {
            Text("No frames yet").foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: LoomTheme.Space.xs) {
                ForEach(messages) { message in
                    HStack(alignment: .top, spacing: LoomTheme.Space.sm) {
                        Image(systemName: message.direction == .clientToServer ? "arrow.up" : "arrow.down")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(message.direction == .clientToServer ? Color.orange : Color.accentColor)
                            .frame(width: 14)
                        CapsuleBadge(text: message.kind.rawValue, hPadding: 5, vPadding: 1)
                        if let text = message.textPayload {
                            Text(text)
                                .font(.callout.monospaced())
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        } else {
                            Text("\(message.payload.count) bytes")
                                .font(.callout.monospaced())
                                .foregroundStyle(.tertiary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
            }
        }
    }
}

/// Headers as an aligned two-column Key/Value table. A `Grid` (not a `Table`)
/// because it lives inside the inspector's `ScrollView` and headers are a small,
/// bounded per-flow set — the key column sizes to its widest name, the value
/// column takes the rest and wraps.
private struct HeadersList: View {
    let headers: [HeaderPair]

    var body: some View {
        if headers.isEmpty {
            Text("No headers").foregroundStyle(.secondary)
        } else {
            Grid(alignment: .leadingFirstTextBaseline,
                 horizontalSpacing: LoomTheme.Space.md,
                 verticalSpacing: LoomTheme.Space.xs) {
                GridRow {
                    Text("Key").gridColumnAlignment(.leading)
                    Text("Value")
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

                Divider().gridCellColumns(2)

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
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct BodyView: View {
    let data: Data?
    let identity: AnyHashable
    /// Above this size the collapsible JSON tree gets janky; show raw text
    /// instead (which itself hands large bodies to the lazy `NSTextView`).
    private let jsonRenderLimit = 200_000

    var body: some View {
        if let data, !data.isEmpty {
            if data.count <= jsonRenderLimit, let json = JSONValue.parse(data), json.isContainer {
                Scrolled { JSONView(value: json) }
            } else {
                RawView(text: String(data: data, encoding: .utf8) ?? "<\(data.count) bytes>", identity: identity)
            }
        } else {
            Scrolled { Text("No body").foregroundStyle(.secondary) }
        }
    }
}

/// Raw text pane. Small payloads use the line-numbered SwiftUI view (`Text` is
/// fine at this size and gives the gutter for reading raw HTTP); large payloads
/// switch to `CodeTextView`, an `NSTextView` that lays out only the visible
/// viewport — the whole body renders, but the main thread never has to lay it
/// all out at once. `identity` changes exactly when the content does, so the
/// heavy text is pushed into the text view only on a real change.
private struct RawView: View {
    let text: String
    let identity: AnyHashable

    var body: some View {
        if text.utf8.count > InspectorText.plainTextThreshold {
            CodeTextView(text: text, identity: identity)
        } else {
            Scrolled { SmallRawText(text: text) }
        }
    }
}

/// The small-payload raw view: monospaced text with a leading line-number
/// gutter.
private struct SmallRawText: View {
    let text: String
    var body: some View {
        let lines = text.isEmpty ? [""] : text.components(separatedBy: "\n")
        HStack(alignment: .top, spacing: LoomTheme.Space.sm) {
            Text((1...lines.count).map(String.init).joined(separator: "\n"))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.trailing)
            Text(lines.joined(separator: "\n"))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.callout.monospaced())
    }
}

/// A plain SwiftUI scroll container with the pane's standard padding — used by
/// every tab that isn't a large text/body (those scroll themselves).
private struct Scrolled<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        ScrollView {
            content
                .padding(LoomTheme.Space.md)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Read-only monospaced text viewer backed by `NSTextView`. Unlike SwiftUI
/// `Text` (which lays its entire string out synchronously), TextKit lays out
/// only the visible viewport, so multi-megabyte bodies scroll smoothly while
/// keeping native selection, Find (⌘F) and copy. Owns its own `NSScrollView` —
/// do not nest it inside a SwiftUI `ScrollView`.
private struct CodeTextView: NSViewRepresentable {
    let text: String
    /// Changes iff `text` changes; lets `updateNSView` skip re-pushing the
    /// (potentially huge) string on unrelated re-renders.
    let identity: AnyHashable

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var applied: AnyHashable?
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        guard let textView = scroll.documentView as? NSTextView else { return scroll }

        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.drawsBackground = false
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.textContainerInset = NSSize(width: LoomTheme.Space.md, height: LoomTheme.Space.sm)
        // Wrap long lines to the pane width (minified JSON can be one huge line).
        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true
        textView.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        textView.textColor = .textColor

        apply(text, to: textView)
        context.coordinator.applied = identity
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let textView = scroll.documentView as? NSTextView else { return }
        guard context.coordinator.applied != identity else { return }
        apply(text, to: textView)
        context.coordinator.applied = identity
    }

    /// Set the whole string in one shot with the fixed monospaced attributes.
    private func apply(_ text: String, to textView: NSTextView) {
        textView.string = text
        textView.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        textView.textColor = .textColor
        textView.scroll(.zero)
    }
}

private struct DiffView: View {
    let original: Flow?
    let replayed: Flow
    var body: some View {
        if let original {
            let lines = diffLines(original: original, replayed: replayed)
            if lines.isEmpty {
                Text("Identical request; response may differ.").foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: LoomTheme.Space.xxs) {
                    ForEach(lines, id: \.self) { Text($0).font(.callout.monospaced()).textSelection(.enabled) }
                }
            }
        }
    }

    private func diffLines(original: Flow, replayed: Flow) -> [String] {
        var lines: [String] = []
        if original.request.method != replayed.request.method {
            lines.append("method: \(original.request.method) → \(replayed.request.method)")
        }
        if original.request.url != replayed.request.url {
            lines.append("url: \(original.request.url) → \(replayed.request.url)")
        }
        let originalHeaders = Dictionary(original.request.headers.map { ($0.name.lowercased(), $0.value) }, uniquingKeysWith: { a, _ in a })
        let replayedHeaders = Dictionary(replayed.request.headers.map { ($0.name.lowercased(), $0.value) }, uniquingKeysWith: { a, _ in a })
        for (name, value) in replayedHeaders.sorted(by: { $0.key < $1.key }) {
            if let old = originalHeaders[name] {
                if old != value { lines.append("header \(name): \(old) → \(value)") }
            } else {
                lines.append("header \(name): (added) \(value)")
            }
        }
        for name in originalHeaders.keys.sorted() where replayedHeaders[name] == nil {
            lines.append("header \(name): (removed)")
        }
        if original.request.body != replayed.request.body { lines.append("body: changed") }
        if original.statusCode != replayed.statusCode {
            lines.append("status: \(original.statusCode.map(String.init) ?? "—") → \(replayed.statusCode.map(String.init) ?? "—")")
        }
        return lines
    }
}
