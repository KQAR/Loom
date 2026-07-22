import AppKit
import SharedModels
import SwiftUI

/// Bottom pane of the main window. Layout referenced from Proxyman (not copied):
/// a left/right split — **Request** on the left, **Response** on the right — each
/// with its own tab strip. Fields are limited to what Loom actually captures.
struct InspectorPanel: View {
    let flow: Flow
    let original: Flow?
    let onReplay: () -> Void
    let onClose: () -> Void

    var body: some View {
        HSplitView {
            RequestPane(flow: flow, original: original, onReplay: onReplay)
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
    let onReplay: () -> Void

    enum Tab: Hashable { case summary, raw, headers, cookies, body, diff }
    @State private var tab: Tab = .summary

    private var cookies: [CookieItem] { CookieParsing.requestCookies(flow.request.headers) }

    private var tabs: [(String, Tab)] {
        var t: [(String, Tab)] = [
            ("Summary", .summary),
            ("Raw", .raw),
            ("Headers(\(flow.request.headers.count))", .headers),
        ]
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
                Button(action: onReplay) {
                    Image(systemName: "arrow.triangle.2.circlepath")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .help("Replay this request")
            }
            .padding(.horizontal, LoomTheme.Space.md)
            .frame(height: 34)
            Divider()

            CopyableURLBar(url: flow.request.url)
            Divider()

            ScrollView {
                Group {
                    switch tab {
                    case .summary: SummaryTable(flow: flow)
                    case .raw: RawView(text: Self.rawText(flow))
                    case .headers: HeadersList(headers: flow.request.headers)
                    case .cookies: CookiesView(cookies: cookies)
                    case .body: BodyView(data: flow.request.body)
                    case .diff: DiffView(original: original, replayed: flow)
                    }
                }
                .padding(LoomTheme.Space.md)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
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

    enum Tab: Hashable { case raw, headers, cookies, body }
    @State private var tab: Tab = .raw

    private var cookies: [CookieItem] {
        CookieParsing.responseCookies(flow.response?.headers ?? [])
    }

    private var tabs: [(String, Tab)] {
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
                    Text("Modified by \(applied.count == 1 ? "rule" : "rules"): \(applied.joined(separator: ", "))")
                        .font(.caption)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                    Spacer(minLength: 0)
                }
                .foregroundStyle(Color.purple)
                .padding(.horizontal, LoomTheme.Space.md)
                .padding(.vertical, LoomTheme.Space.xs)
                .background(Color.purple.opacity(0.08))
                Divider()
            }

            ScrollView {
                Group {
                    if let response = flow.response {
                        switch tab {
                        case .raw: RawView(text: Self.rawText(flow))
                        case .headers: HeadersList(headers: response.headers)
                        case .cookies: CookiesView(cookies: cookies)
                        case .body: BodyView(data: response.body)
                        }
                    } else if let error = flow.error {
                        Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                    } else {
                        Text("Waiting for response…").foregroundStyle(.secondary)
                    }
                }
                .padding(LoomTheme.Space.md)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .overlay(alignment: .topTrailing) {
                if tab == .body, let text = RequestPane.bodyText(flow.response?.body) {
                    FloatingCopyButton(text: text)
                }
            }
        }
        .onChange(of: flow.id) {
            if tab == .cookies, cookies.isEmpty { tab = .raw }
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
        Text(method)
            .font(.caption.monospaced().weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(.quaternary, in: Capsule())
    }
}

private struct StatusBadge: View {
    let code: Int?
    var body: some View {
        let color = code.map { LoomTheme.statusColor(status: $0, isError: false) } ?? .red
        Text(code.map(String.init) ?? "ERR")
            .font(.caption.monospacedDigit().weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(color.opacity(0.15), in: Capsule())
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
                row("Rules", applied.joined(separator: ", "), color: .purple)
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

private struct HeadersList: View {
    let headers: [HeaderPair]
    var body: some View {
        if headers.isEmpty {
            Text("No headers").foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: LoomTheme.Space.xxs) {
                ForEach(headers) { header in
                    HStack(alignment: .top, spacing: LoomTheme.Space.xs) {
                        Text(header.name).foregroundStyle(.secondary)
                        Text(header.value).textSelection(.enabled)
                    }
                    .font(.callout.monospaced())
                }
            }
        }
    }
}

private struct BodyView: View {
    let data: Data?
    /// Above this size the collapsible tree gets janky; show raw text instead.
    private let jsonRenderLimit = 200_000

    var body: some View {
        if let data, !data.isEmpty {
            if data.count <= jsonRenderLimit, let json = JSONValue.parse(data), json.isContainer {
                JSONView(value: json)
            } else {
                RawView(text: String(data: data, encoding: .utf8) ?? "<\(data.count) bytes>")
            }
        } else {
            Text("No body").foregroundStyle(.secondary)
        }
    }
}

/// Monospaced text with a leading line-number gutter.
private struct RawView: View {
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
