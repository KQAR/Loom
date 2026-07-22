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

    enum Tab: Hashable { case summary, headers, body, diff }
    @State private var tab: Tab = .summary

    private var tabs: [(String, Tab)] {
        var t: [(String, Tab)] = [
            ("Summary", .summary),
            ("Headers(\(flow.request.headers.count))", .headers),
            ("Body", .body),
        ]
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
                    case .headers: HeadersList(headers: flow.request.headers)
                    case .body: BodyView(data: flow.request.body)
                    case .diff: DiffView(original: original, replayed: flow)
                    }
                }
                .padding(LoomTheme.Space.md)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .onChange(of: flow.id) {
            if tab == .diff, original == nil { tab = .summary }
        }
    }
}

// MARK: - Response (right)

private struct ResponsePane: View {
    let flow: Flow
    let onClose: () -> Void

    enum Tab: Hashable { case headers, body, raw }
    @State private var tab: Tab = .body

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: LoomTheme.Space.sm) {
                InspectorTabStrip(tabs: [
                    ("Headers(\(flow.response?.headers.count ?? 0))", .headers),
                    ("Body", .body),
                    ("Raw", .raw),
                ], selection: $tab)
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

            ScrollView {
                Group {
                    if let response = flow.response {
                        switch tab {
                        case .headers: HeadersList(headers: response.headers)
                        case .body: BodyView(data: response.body)
                        case .raw: RawView(text: Self.rawText(flow))
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
    var body: some View {
        if let data, !data.isEmpty {
            RawView(text: String(data: data, encoding: .utf8) ?? "<\(data.count) bytes>")
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
