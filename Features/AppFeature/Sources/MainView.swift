import AppKit
import ComposableArchitecture
import LoomSharedModels
import SwiftUI

/// The main window. Layout follows standard HTTP-debugger conventions (Proxyman/Charles-style):
/// left category sidebar, then a vertical split — a multi-column request table
/// on top, a tabbed inspector below.
public struct MainView: View {
    @Bindable var store: StoreOf<AppFeature>
    /// Tail-follow the newest row until the user scrolls away.
    @State private var followTail = true
    /// Fill of the clear button's charging ring (0…1) while it's held.
    @State private var clearProgress: CGFloat = 0
    /// The clear control is a small dot at rest, expanding to the full button when
    /// the cursor is over/near it.
    @State private var clearHovering = false
    /// Whether the SSL button's cert install-&-trust popover is open.
    @State private var showingCertTrust = false

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
            Label("Rules", systemImage: "wand.and.stars")
                .badge(store.rules.rulesState.rules.count)
                .tag(FlowCategory.rules)
            Label("Audit", systemImage: "checklist")
                .badge(store.auditEntries.count)
                .tag(FlowCategory.audit)
            breakpointsSidebarRow

            if !store.devices.isEmpty {
                Section("Devices") {
                    ForEach(store.devices, id: \.device.groupingKey) { entry in
                        let ip = entry.device.groupingKey
                        let alias = store.deviceAliases[ip]
                        Label {
                            Text(alias ?? entry.device.displayName)
                        } icon: {
                            Image(systemName: entry.device.kind == .lan ? "iphone" : "desktopcomputer")
                        }
                        .badge(entry.count)
                        .tag(FlowCategory.device(ip))
                        .help(entry.device.typeSummary.map { "\($0) · \(entry.device.ip)" } ?? entry.device.ip)
                        .contextMenu {
                            Button(alias == nil ? "Set Alias…" : "Rename…", systemImage: "pencil") {
                                promptDeviceAlias(ip: ip, current: alias ?? "")
                            }
                            if alias != nil {
                                Button("Clear Alias", systemImage: "xmark.circle") {
                                    store.send(.setDeviceAlias(ip: ip, alias: nil))
                                }
                            }
                        }
                    }
                }
            }

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

    /// Breakpoints category. While something is held the row goes orange and its
    /// badge counts *held exchanges*, not armed breakpoints — a parked live
    /// connection is the thing the human has to act on; how many breakpoints an
    /// agent armed is only interesting when none of them is holding anything.
    private var breakpointsSidebarRow: some View {
        let held = store.breakpoints.heldCount
        return Label {
            Text("Breakpoints")
                .foregroundStyle(held > 0 ? Color.orange : .primary)
        } icon: {
            Image(systemName: held > 0 ? "pause.circle.fill" : "pause.circle")
                .foregroundStyle(held > 0 ? Color.orange : .secondary)
        }
        .badge(held > 0 ? held : store.breakpoints.armed.count)
        .tag(FlowCategory.breakpoints)
        .help(held > 0
            ? "\(held) exchange\(held == 1 ? "" : "s") held — the client is still waiting"
            : "Breakpoints armed by your agent")
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
                // The clear control floats over the table (bottom-right): a small red
                // dot at rest, expanding to the full hold-to-clear button on hover, so
                // it barely covers content until you reach for it. No reserved gap —
                // the table keeps full height and the row stripes fill it.
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    if store.droppedFlowCount > 0 { capBanner }
                }
                .overlay(alignment: .bottomTrailing) { clearFAB }
        }
    }

    /// Honest "you're not seeing everything" strip: the session cap has dropped
    /// the oldest flows, so a huge capture doesn't masquerade as complete.
    private var capBanner: some View {
        HStack(spacing: LoomTheme.Space.xs) {
            Image(systemName: "clock.arrow.circlepath").font(.caption2)
            Text("Showing the latest \(AppFeature.State.displayCap) · \(store.droppedFlowCount) older cleared")
                .font(.caption)
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, LoomTheme.Space.sm)
        .padding(.vertical, LoomTheme.Space.xxs)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.bar)
    }

    /// How long the clear button must be held to fire. The gesture and the ring
    /// that charges around it read from the same constant: they are one signal —
    /// the ring *is* the countdown — and if they drift the ring either fills
    /// before the gesture fires or the press completes on a half-full ring.
    private static let clearHoldDuration: TimeInterval = 0.7

    /// Destructive "clear captured flows", floated bottom-right of the flow list.
    /// At rest it's just a small red dot so it barely covers the table; hovering
    /// (or reaching toward it) expands it to the full button. Held to fire — a red
    /// ring charges around the trash glyph while held and springs back if released
    /// early, so a stray click can't wipe the capture (no modal dialog).
    private var clearFAB: some View {
        ZStack {
            if clearHovering {
                ZStack {
                    Circle()
                        .fill(.regularMaterial)
                        .overlay { Circle().strokeBorder(.quaternary, lineWidth: 1) }
                    Circle()
                        .trim(from: 0, to: clearProgress)
                        .stroke(Color.red, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        .rotationEffect(.degrees(-90)) // start the fill at 12 o'clock
                        .padding(3)
                    Image(systemName: "trash")
                        .font(LoomTheme.Icon.fab)
                        .foregroundStyle(Color.red)
                }
                // Grow out of the dot: scale up from the corner + fade in.
                .transition(.scale(scale: 0.3, anchor: .bottomTrailing).combined(with: .opacity))
            } else {
                Circle()
                    .fill(Color.red)
                    .frame(width: 12, height: 12)
                    .transition(.scale(scale: 0.5).combined(with: .opacity))
            }
        }
        .frame(width: clearHovering ? 44 : 22, height: clearHovering ? 44 : 22)
        .shadow(color: .black.opacity(0.25), radius: clearHovering ? 4 : 2, y: clearHovering ? 2 : 1)
        .contentShape(Circle())
        .animation(.spring(response: 0.28, dampingFraction: 0.72), value: clearHovering)
        .onHover { hovering in
            clearHovering = hovering
        }
        .onLongPressGesture(minimumDuration: Self.clearHoldDuration, maximumDistance: 60) {
            store.send(.clearTapped)
            clearProgress = 0
        } onPressingChanged: { pressing in
            // Pressing implies the cursor is on it — keep it expanded while held.
            if pressing { clearHovering = true }
            withAnimation(pressing ? .linear(duration: Self.clearHoldDuration) : .easeOut(duration: 0.2)) {
                clearProgress = pressing ? 1 : 0
            }
        }
        .help(clearHovering ? "Hold to clear captured flows" : "Clear captured flows")
        .padding(LoomTheme.Space.md)
    }

    private var requestTable: some View {
        // Evaluated once per render and reused: `displayFlows` filters the capture,
        // and the auto-scroll modifier below needs its count too.
        let rows = store.displayFlows
        return Table(rows, selection: $store.selectedFlowID.sending(\.flowSelected)) {
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
                // One parse per row, shared by the favicon and the label.
                let host = Self.host(flow.request.url)
                HStack(spacing: 6) {
                    FaviconView(host: host)
                    Text(host)
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
                    // Loaded from a file, not seen on this machine's wire. Marked for
                    // the same reason a replay is: the row would otherwise read as
                    // something that just happened here.
                    if let importedFrom = flow.importedFrom {
                        Image(systemName: "tray.and.arrow.down")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .help("Imported from \(importedFrom)")
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
        .background(RequestTableAutoScroll(rowCount: rows.count, follow: $followTail))
        .contextMenu(forSelectionType: Flow.ID.self) { ids in
            if let id = ids.first, let flow = store.flows[id: id] {
                // Parsed once for the whole menu, not once per action closure.
                let host = Self.host(flow.request.url)
                Button("Replay", systemImage: "arrow.triangle.2.circlepath") {
                    store.send(.replayTapped(id))
                }
                Divider()
                Menu("Copy") {
                    Button("Host") { Self.copy(host) }
                    Button("Path") { Self.copy(Self.path(flow.request.url)) }
                    Button("URL") { Self.copy(flow.request.url) }
                    Divider()
                    Button("as cURL") { store.send(.copyCurlTapped(id)) }
                }
                Menu("Add Rule") {
                    Button("Mock This Response") { store.send(.addRuleFromFlow(id, .mockResponse)) }
                        .disabled(flow.response == nil)
                    Divider()
                    Button("Block This URL") { store.send(.addRuleFromFlow(id, .blockURL)) }
                    Button("Block Host \(host)") {
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


    // MARK: Content — table only, or table + inspector when a flow is selected

    @ViewBuilder private var content: some View {
        if store.selectedCategory == .rules {
            RulesPanelView(store: store.scope(state: \.rules, action: \.rules))
        } else if store.selectedCategory == .audit {
            AuditPanelView(store: store)
        } else if store.selectedCategory == .breakpoints {
            BreakpointsPanelView(store: store.scope(state: \.breakpoints, action: \.breakpoints))
        } else if let flow = store.selectedFlow {
            VSplitView {
                requestArea
                    .frame(minHeight: 160, idealHeight: 280, maxHeight: .infinity)
                InspectorPanel(
                    // The hydrated detail (with bodies) once it lands; the
                    // metadata-only list row until then, so the panel appears
                    // immediately and its body fills in.
                    flow: store.selectedFlowDetail ?? flow,
                    original: store.selectedOriginalDetail,
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

    /// Prompt for a device alias (a plain AppKit sheet — iOS won't give us the
    /// real name, so the human names it). Empty input clears the alias.
    private func promptDeviceAlias(ip: String, current: String) {
        let alert = NSAlert()
        alert.messageText = "Device alias"
        alert.informativeText = ip
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
        field.stringValue = current
        field.placeholderString = "e.g. Jarvis-iPhone"
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        if alert.runModal() == .alertFirstButtonReturn {
            let value = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            store.send(.setDeviceAlias(ip: ip, alias: value.isEmpty ? nil : value))
        }
    }

    /// Phone/QR onboarding entry, right of the toolbar's ip:port chip.
    private var phoneButton: some View {
        Button {
            store.send(.phoneButtonTapped(.mainWindow))
        } label: {
            Image(systemName: "iphone")
                // Highlighted while LAN device connection is allowed (default on).
                .foregroundStyle(store.lanEnabled ? Color.accentColor : .secondary)
        }
        .buttonStyle(.borderless)
        .accessibilityLabel("Set up a phone to capture its traffic")
        .help("Set up a phone to capture its traffic")
        .popover(item: phonePopover, arrowEdge: .bottom) { phoneStore in
            PhoneOnboardingView(store: phoneStore)
        }
    }

    /// The phone popover, gated to the main window: nil unless the main window
    /// opened it, so tapping the panel's Connect Device row doesn't also pop it here.
    private var phonePopover: Binding<StoreOf<PhoneOnboardingFeature>?> {
        let scoped = $store.scope(state: \.phone, action: \.phone)
        return Binding(
            get: { store.phoneOrigin == .mainWindow ? scoped.wrappedValue : nil },
            set: { scoped.wrappedValue = $0 }
        )
    }

    @ToolbarContentBuilder private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            HStack(spacing: LoomTheme.Space.xs) {
                // green = proxy up & recording · yellow = up but paused · grey = off.
                Circle()
                    .fill(captureDotColor)
                    .frame(width: 7, height: 7)
                Text(verbatim: store.status.isRunning
                    ? "\(store.displayHost):\(store.status.port)"
                    : "Proxy stopped")
                    .font(.callout.monospaced())
                    .foregroundStyle(.secondary)

                if store.status.isRunning { phoneButton }

                Divider().frame(height: 14)

                statusIcon("globe", on: store.setup.isSystemProxy,
                           help: store.setup.isSystemProxy ? "System proxy: on" : "System proxy: off") {
                    store.send(.setup(.toggleSystemProxyTapped))
                }
                sslButton
                statusIcon("wand.and.stars", on: store.rules.rulesEnabled,
                           help: store.rules.rulesEnabled ? "Map / rewrite (mock): on" : "Map / rewrite (mock): off") {
                    store.send(.rules(.toggleRulesTapped))
                }

                // Record lives at the right end of the ip toolbar, split from the
                // status toggles by a divider. Clear is a floating button in the
                // flow list (`clearFAB`), so the trailing toolbar group is gone.
                Divider().frame(height: 14)
                recordButton
            }
            .padding(.horizontal, LoomTheme.Space.sm)
        }
    }

    /// green = proxy up & recording · yellow = up but recording paused · grey = off.
    private var captureDotColor: Color {
        guard store.status.isRunning else { return .secondary }
        return store.isRecording ? .green : .yellow
    }

    /// Start/stop capture. Idle shows a circular record symbol; recording shows a
    /// stop glyph. Text label kept ("Record"/"Stop").
    private var recordButton: some View {
        Button { store.send(.toggleRecordingTapped) } label: {
            HStack(spacing: 5) {
                Image(systemName: store.isRecording ? "stop.fill" : "record.circle")
                    .font(LoomTheme.Icon.toolbar)
                Text(store.isRecording ? "Stop" : "Record")
                    .font(.callout)
            }
            .foregroundStyle(store.isRecording ? Color.orange : Color.red)
            .frame(height: 26)
            .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help(store.isRecording
            ? "Stop recording — traffic keeps flowing but isn't captured"
            : "Start recording captured traffic")
    }

    /// SSL proxying toggle with a cert-trust affordance. When SSL is on but the
    /// root CA isn't trusted yet, HTTPS can't be decrypted — the icon goes **yellow**
    /// and a tap opens the same install-&-trust popover as the status-bar panel
    /// (reusing `CertificateTrustCard`) instead of toggling. Otherwise it's the
    /// normal on/off toggle (green when on).
    private var sslButton: some View {
        let needsTrust = store.setup.sslEnabled && !store.setup.certificateStatus.trustState.isReady
        return Button {
            if needsTrust { showingCertTrust = true }
            else { store.send(.setup(.toggleSSLTapped)) }
        } label: {
            Image(systemName: "lock.shield")
                .font(LoomTheme.Icon.toolbar)
                .foregroundStyle(needsTrust ? Color.yellow : (store.setup.sslEnabled ? Color.green : Color.secondary))
                .frame(width: 30, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .accessibilityLabel("SSL proxying")
        .accessibilityValue(needsTrust ? "on, certificate not trusted" : (store.setup.sslEnabled ? "on" : "off"))
        .help(needsTrust
            ? "HTTPS interception is on but the CA isn't trusted — click to install & trust"
            : (store.setup.sslEnabled ? "SSL proxying: on" : "SSL proxying: off"))
        .popover(isPresented: $showingCertTrust, arrowEdge: .bottom) {
            CertificateTrustCard(store: store.scope(state: \.setup, action: \.setup))
                .frame(width: 320)
                .padding(LoomTheme.Space.md)
        }
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
        .accessibilityLabel(help)
        .accessibilityValue(on ? "on" : "off")
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

    /// Both go through `URLHost`, which exists for exactly this call site: a row
    /// body runs per visible row per redraw, and these used to build a
    /// `URLComponents` each time — the cost `Flow.host` and the sidebar's host
    /// filter were already moved off. Cache the result per row rather than calling
    /// twice for the same string.
    static func host(_ raw: String) -> String { URLHost.host(ofURLString: raw) ?? raw }
    static func path(_ raw: String) -> String { URLHost.pathAndQuery(ofURLString: raw) }
}

// MARK: - Status pill (table Status column)

/// Request status as a color dot: green 2xx · orange 3xx · red 4xx/5xx/error.
/// An in-flight request (no response yet, no error) shows a small spinner instead
/// of a static dot, so "still running" reads at a glance. The numeric code stays
/// reachable as a tooltip (color isn't the only signal) and in the inspector.
struct StatusDot: View {
    let flow: Flow

    /// No response head and no error yet → the request is still in flight.
    private var isInFlight: Bool { flow.statusCode == nil && flow.error == nil }

    var body: some View {
        Group {
            if isInFlight {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.6) // fit the 28pt status column without inflating row height
                    .frame(width: 14, height: 14)
            } else {
                Circle()
                    .fill(LoomTheme.statusColor(status: flow.statusCode, isError: flow.error != nil))
                    .frame(width: 9, height: 9)
            }
        }
        .help(statusText)
    }

    private var statusText: String {
        if let code = flow.statusCode { return "\(code)" }
        if flow.error != nil { return "Error" }
        return "In flight"
    }
}
