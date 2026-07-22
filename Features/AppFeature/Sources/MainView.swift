import ComposableArchitecture
import SharedModels
import SwiftUI

/// The main window. Layout follows standard HTTP-debugger conventions (Proxyman/Charles-style):
/// left category sidebar, then a vertical split — a multi-column request table
/// on top, a tabbed inspector below.
public struct MainView: View {
    @Bindable var store: StoreOf<AppFeature>

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
        .task { store.send(.task) }
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

            if !store.apps.isEmpty {
                Section("Apps") {
                    ForEach(store.apps, id: \.app.groupingKey) { entry in
                        Label {
                            Text(entry.app.name)
                        } icon: {
                            AppIconView(app: entry.app)
                        }
                        .badge(entry.count)
                        .tag(FlowCategory.app(entry.app.groupingKey))
                    }
                }
            }

            Section("Hosts") {
                ForEach(store.hosts, id: \.host) { entry in
                    Label {
                        Text(entry.host)
                    } icon: {
                        FaviconView(host: entry.host)
                    }
                    .badge(entry.count)
                    .tag(FlowCategory.host(entry.host))
                }
            }
        }
        .listStyle(.sidebar)
        .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 300)
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
                StatusPill(flow: flow)
            }
            .width(54)

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
                }
            }

            TableColumn("Time") { flow in
                Text(flow.durationMS.map { "\($0)ms" } ?? "—")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .width(min: 56, ideal: 70, max: 100)
        }
    }

    // MARK: Content — table only, or table + inspector when a flow is selected

    @ViewBuilder private var content: some View {
        if let flow = store.selectedFlow {
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

                statusIcon("globe", on: store.isSystemProxy,
                           help: store.isSystemProxy ? "System proxy: on" : "System proxy: off") {
                    store.send(.toggleSystemProxyTapped)
                }
                statusIcon("lock.shield", on: store.sslEnabled,
                           help: store.sslEnabled ? "SSL proxying: on" : "SSL proxying: off") {
                    store.send(.toggleSSLTapped)
                }
                statusIcon("wand.and.stars", on: store.rulesEnabled,
                           help: store.rulesEnabled ? "Map / rewrite (mock): on" : "Map / rewrite (mock): off") {
                    store.send(.toggleRulesTapped)
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
                    .font(.system(size: 16, weight: .semibold))
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
                .font(.system(size: 16, weight: .semibold))
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
                .font(.system(size: 16, weight: .semibold))
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

struct StatusPill: View {
    let flow: Flow

    var body: some View {
        Group {
            if let code = flow.statusCode {
                pill(text: "\(code)", color: LoomTheme.statusColor(status: code, isError: false))
            } else if flow.error != nil {
                pill(text: "ERR", color: .red)
            } else {
                ProgressView().controlSize(.small).frame(width: 44, height: 20)
            }
        }
    }

    private func pill(text: String, color: Color) -> some View {
        Text(text)
            .font(.caption.monospacedDigit().weight(.semibold))
            .foregroundStyle(color)
            .frame(width: 44, height: 20)
            .background(color.opacity(0.15), in: RoundedRectangle(cornerRadius: LoomTheme.Radius.sm))
    }
}
