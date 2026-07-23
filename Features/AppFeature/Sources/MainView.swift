import AppKit
import ComposableArchitecture
import SharedModels
import SwiftUI

/// The main window. Layout follows standard HTTP-debugger conventions (Proxyman/Charles-style):
/// left category sidebar, then a vertical split — a multi-column request table
/// on top, a tabbed inspector below.
public struct MainView: View {
    @Bindable var store: StoreOf<AppFeature>
    /// Tail-follow the newest row until the user scrolls away.
    @State private var followTail = true

    public init(store: StoreOf<AppFeature>) {
        self.store = store
    }

    public var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            content
                .toolbar { toolbarContent }
        }
        .task { store.send(.viewAppeared) }
        .sheet(item: $store.scope(state: \.rules.editor, action: \.rules.editor)) { editorStore in
            RuleEditorView(store: editorStore)
        }
    }

    // MARK: Sidebar — categories

    private var sidebar: some View {
        List(selection: $store.selectedCategory.sending(\.categorySelected)) {
            Label("All Flows", systemImage: "tray.full")
                .badge(store.allCount)
                .tag(FlowCategory.all)
            Label("Errors", systemImage: "exclamationmark.triangle")
                .badge(store.errorCount)
                .tag(FlowCategory.errors)
            Label("Replayed", systemImage: "arrow.triangle.2.circlepath")
                .badge(store.replayedCount)
                .tag(FlowCategory.replayed)
            Label("Rules", systemImage: "wand.and.stars")
                .badge(store.rules.rulesState.rules.count)
                .tag(FlowCategory.rules)

            if !store.apps.isEmpty {
                Section("Apps") {
                    ForEach(store.apps, id: \.app.groupingKey) { entry in
                        let key = entry.app.groupingKey
                        let pinned = store.pinnedApps.contains(key)
                        Label {
                            rowTitle(entry.app.name, pinned: pinned)
                        } icon: {
                            AppIconView(app: entry.app)
                        }
                        .badge(entry.count)
                        .tag(FlowCategory.app(key))
                        .contextMenu {
                            Button(pinned ? "Unpin" : "Pin", systemImage: pinned ? "pin.slash" : "pin") {
                                store.send(.pinAppToggled(key))
                            }
                        }
                    }
                }
            }

            Section("Hosts") {
                ForEach(store.hosts, id: \.host) { entry in
                    let pinned = store.pinnedHosts.contains(entry.host)
                    Label {
                        rowTitle(entry.host, pinned: pinned)
                    } icon: {
                        FaviconView(host: entry.host)
                    }
                    .badge(entry.count)
                    .tag(FlowCategory.host(entry.host))
                    .contextMenu {
                        Button(pinned ? "Unpin" : "Pin", systemImage: pinned ? "pin.slash" : "pin") {
                            store.send(.pinHostToggled(entry.host))
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 300)
    }

    /// Sidebar row title with a trailing pin glyph when pinned.
    @ViewBuilder private func rowTitle(_ text: String, pinned: Bool) -> some View {
        HStack(spacing: 4) {
            Text(text).lineLimit(1).truncationMode(.middle)
            if pinned {
                Image(systemName: "pin.fill")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Request area (table, or a full-bleed empty state)

    @ViewBuilder private var requestArea: some View {
        if store.displayFlows.isEmpty {
            emptyState.frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            requestTable
        }
    }

    private var requestTable: some View {
        Table(store.displayFlows, selection: $store.selectedFlowID.sending(\.flowSelected)) {
            TableColumn("") { flow in
                StatusDot(flow: flow)
                    .frame(maxWidth: .infinity, alignment: .center)
            }
            .width(28)

            TableColumn("#") { flow in
                // 1-based capture order: position in the oldest-first store + 1.
                Text("\((store.flows.index(id: flow.id) ?? 0) + 1)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            .width(min: 36, ideal: 44, max: 64)

            TableColumn("App") { flow in
                AppIconView(app: flow.sourceApp)
                    .help(flow.sourceApp?.name ?? "Unknown app")
            }
            .width(36)

            TableColumn("Method") { flow in
                Text(flow.request.method).font(.callout.monospaced())
            }
            .width(min: 52, ideal: 62, max: 90)

            TableColumn("Host") { flow in
                HStack(spacing: 6) {
                    FaviconView(host: Self.host(flow.request.url))
                    Text(Self.host(flow.request.url))
                        .font(.callout.monospaced())
                        .foregroundStyle(.secondary)
                }
            }
            .width(min: 110, ideal: 180, max: 280)

            TableColumn("Path") { flow in
                HStack(spacing: LoomTheme.Space.xs) {
                    Text(Self.path(flow.request.url))
                        .font(.callout.monospaced())
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if flow.replayedFrom != nil {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(.caption2)
                            .foregroundStyle(Color.accentColor)
                    }
                    if let applied = flow.appliedRules, !applied.isEmpty {
                        Image(systemName: "wand.and.stars")
                            .font(.caption2)
                            .foregroundStyle(Color.accentColor)
                            .help("Modified by rules: \(applied.map(\.name).joined(separator: ", "))")
                    }
                    if flow.isWebSocket {
                        Image(systemName: "bolt.horizontal.circle")
                            .font(.caption2)
                            .foregroundStyle(Color.accentColor)
                            .help("WebSocket · \(flow.webSocketMessages?.count ?? 0) messages")
                    }
                }
            }

            TableColumn("Time") { flow in
                Text(flow.durationMS.map { "\($0)ms" } ?? "—")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .width(min: 56, ideal: 70, max: 100)
        }
        .background(RequestTableAutoScroll(rowCount: store.displayFlows.count, follow: $followTail))
        .contextMenu(forSelectionType: Flow.ID.self) { ids in
            if let id = ids.first, let flow = store.flows[id: id] {
                Menu("Copy") {
                    Button("Host") { Self.copy(Self.host(flow.request.url)) }
                    Button("Path") { Self.copy(Self.path(flow.request.url)) }
                    Button("URL") { Self.copy(flow.request.url) }
                    Divider()
                    Button("as cURL") { Self.copy(Self.curlCommand(flow)) }
                }
                Menu("Add Rule") {
                    Button("Mock This Response") { store.send(.addRuleFromFlow(id, .mockResponse)) }
                        .disabled(flow.response == nil)
                    Divider()
                    Button("Block This URL") { store.send(.addRuleFromFlow(id, .blockURL)) }
                    Button("Block Host \(Self.host(flow.request.url))") {
                        store.send(.addRuleFromFlow(id, .blockHost))
                    }
                }
            }
        }
    }

    private static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// Reconstruct a runnable `curl` for the captured request: method, URL,
    /// headers (minus ones curl sets itself), and body. Single-quoted with proper
    /// `'\''` escaping, line-continued for readability.
    static func curlCommand(_ flow: Flow) -> String {
        let request = flow.request
        var parts: [String] = ["curl"]
        if request.method.uppercased() != "GET" {
            parts.append("-X \(request.method)")
        }
        parts.append("'\(shellEscape(request.url))'")
        for header in request.headers where !curlOmittedHeader(header.name) {
            parts.append("-H '\(shellEscape("\(header.name): \(header.value)"))'")
        }
        if let body = request.body, !body.isEmpty {
            let text = String(data: body, encoding: .utf8) ?? ""
            if !text.isEmpty { parts.append("--data '\(shellEscape(text))'") }
        }
        return parts.joined(separator: " \\\n  ")
    }

    private static func curlOmittedHeader(_ name: String) -> Bool {
        ["content-length", "host"].contains(name.lowercased())
    }

    /// Escape a string for embedding inside single quotes in a POSIX shell.
    private static func shellEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "'", with: "'\\''")
    }

    // MARK: Content — table only, or table + inspector when a flow is selected

    @ViewBuilder private var content: some View {
        if store.selectedCategory == .rules {
            RulesPanelView(store: store.scope(state: \.rules, action: \.rules))
        } else if let flow = store.selectedFlow {
            VSplitView {
                requestArea
                    .frame(minHeight: 160, idealHeight: 280, maxHeight: .infinity)
                InspectorPanel(
                    flow: flow,
                    original: flow.replayedFrom.flatMap { store.flows[id: $0] },
                    onReplay: { store.send(.replayTapped(flow.id)) },
                    onClose: { store.send(.flowSelected(nil)) }
                )
                .frame(minHeight: 160, maxHeight: .infinity)
            }
        } else {
            requestArea
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: Toolbar

    @ToolbarContentBuilder private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            HStack(spacing: LoomTheme.Space.xs) {
                Circle()
                    .fill(store.status.isRunning ? Color.green : Color.secondary)
                    .frame(width: 7, height: 7)
                Text(verbatim: store.status.isRunning
                    ? "\(store.displayHost):\(store.status.port)"
                    : "Proxy stopped")
                    .font(.callout.monospaced())
                    .foregroundStyle(.secondary)

                Divider().frame(height: 14)

                statusIcon("globe", on: store.setup.isSystemProxy,
                           help: store.setup.isSystemProxy ? "System proxy: on" : "System proxy: off") {
                    store.send(.setup(.toggleSystemProxyTapped))
                }
                statusIcon("lock.shield", on: store.setup.sslEnabled,
                           help: store.setup.sslEnabled ? "SSL proxying: on" : "SSL proxying: off") {
                    store.send(.setup(.toggleSSLTapped))
                }
                statusIcon("wand.and.stars", on: store.rules.rulesEnabled,
                           help: store.rules.rulesEnabled ? "Map / rewrite (mock): on" : "Map / rewrite (mock): off") {
                    store.send(.rules(.toggleRulesTapped))
                }
            }
            .padding(.horizontal, LoomTheme.Space.sm)
        }
        // macOS 26 wraps a ToolbarItemGroup in a shared Liquid Glass container;
        // hide it so these read as flat icons. Plain group on the 14 baseline.
        if #available(macOS 26.0, *) {
            ToolbarItemGroup(placement: .primaryAction) { trailingButtons }
                .sharedBackgroundVisibility(.hidden)
        } else {
            ToolbarItemGroup(placement: .primaryAction) { trailingButtons }
        }
    }

    @ViewBuilder private var trailingButtons: some View {
        Button { store.send(.toggleRecordingTapped) } label: {
            HStack(spacing: 5) {
                Image(systemName: store.isRecording ? "stop.fill" : "play.fill")
                    .font(LoomTheme.Icon.toolbar)
                Text(store.isRecording ? "Stop" : "Record")
                    .font(.callout)
            }
            .foregroundStyle(store.isRecording ? Color.orange : Color.primary)
            .frame(height: 26)
            .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help(store.isRecording
            ? "Stop recording — traffic keeps flowing but isn't captured"
            : "Start recording captured traffic")

        barButton(
            "xmark.bin",
            help: "Clear captured flows",
            disabled: store.flows.isEmpty
        ) { store.send(.clearTapped) }
    }

    /// A plain toolbar icon button — no Liquid Glass container, larger tap target.
    private func barButton(
        _ symbol: String,
        color: Color = .primary,
        help: String,
        disabled: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(LoomTheme.Icon.toolbar)
                .foregroundStyle(color)
                .frame(width: 30, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .disabled(disabled)
        .help(help)
    }

    private func statusIcon(_ symbol: String, on: Bool, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(LoomTheme.Icon.toolbar)
                .foregroundStyle(on ? Color.green : Color.secondary)
                .frame(width: 30, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help(help)
    }

    @ViewBuilder private var emptyState: some View {
        if store.status.isRunning {
            ContentUnavailableView {
                Label("Waiting for traffic", systemImage: "dot.radiowaves.left.and.right")
            } description: {
                Text("Send requests through \(store.displayHost):\(String(store.status.port))\n`curl -x http://\(store.displayHost):\(String(store.status.port)) http://…`")
            }
        } else {
            ContentUnavailableView {
                Label("Proxy stopped", systemImage: "pause.circle")
            } description: {
                Text("Start the proxy from the menu-bar console.")
            }
        }
    }

    static func host(_ raw: String) -> String { URLComponents(string: raw)?.host ?? raw }
    static func path(_ raw: String) -> String {
        guard let c = URLComponents(string: raw) else { return raw }
        let path = c.path.isEmpty ? "/" : c.path
        return path + (c.query.map { "?\($0)" } ?? "")
    }
}

// MARK: - Status pill (table Status column)

/// Request status as a color dot: green 2xx · orange 3xx · red 4xx/5xx/error ·
/// gray in-flight. The numeric code stays reachable as a tooltip (color isn't the
/// only signal) and in the inspector.
struct StatusDot: View {
    let flow: Flow

    var body: some View {
        Circle()
            .fill(LoomTheme.statusColor(status: flow.statusCode, isError: flow.error != nil))
            .frame(width: 9, height: 9)
            .help(statusText)
    }

    private var statusText: String {
        if let code = flow.statusCode { return "\(code)" }
        if flow.error != nil { return "Error" }
        return "In flight"
    }
}
