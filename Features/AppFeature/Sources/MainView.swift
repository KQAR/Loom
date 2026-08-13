import AppKit
import ComposableArchitecture
import LoomSharedModels
import SwiftUI

/// The main window. Layout follows standard HTTP-debugger conventions (Proxyman/Charles-style):
/// left category sidebar, then a vertical split — a multi-column request table
/// on top, a tabbed inspector below.
public struct MainView: View {
    @Bindable var store: StoreOf<AppFeature>
    /// The capture surface, scoped once. Views that are *only* about captured traffic
    /// (the table, the find bar) take this rather than the whole app store, so a
    /// change to, say, the helper's install state cannot invalidate the table.
    private var captureStore: StoreOf<CaptureFeature> {
        store.scope(state: \.capture, action: \.capture)
    }
    /// Tail-follow the newest row until the user scrolls away.
    @State private var followTail = true
    /// Fill of the clear button's charging ring (0…1) while it's held.
    @State private var clearProgress: CGFloat = 0
    /// The clear control is a small dot at rest, expanding to the full button when
    /// the cursor is over/near it.
    @State private var clearHovering = false
    /// Whether the SSL button's cert install-&-trust popover is open.
    @State private var showingCertTrust = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Sidebar visibility — hand-rolled because the container has no built-in collapse
    /// (see the container note on `body`).
    @State private var sidebarVisible = true
    /// Collapse state of the two grouping sections. Persisted (`@AppStorage`) rather
    /// than plain `@State`: these grow without bound during a capture — hosts especially,
    /// which is why they're the sections worth collapsing — so a human who folds Hosts
    /// away to keep Devices in view would otherwise have it unfold on every
    /// relaunch. View-local chrome, so it stays out of `AppFeature.State`; unlike pins
    /// (`PinsStore`) nothing but this view ever reads it.
    @AppStorage("com.loom.sidebar.devicesExpanded") private var devicesExpanded = true
    @AppStorage("com.loom.sidebar.hostsExpanded") private var hostsExpanded = true
    /// Which devices have had their app list folded away, as a `\n`-joined list of
    /// IPs.
    ///
    /// The **collapsed** set rather than the expanded one, which is the load-bearing
    /// half: a device Loom has never seen before is not in it, so it arrives
    /// expanded and its apps are visible the moment the phone starts talking. Storing
    /// the expanded set would have every new device show up folded, which on the one
    /// surface someone opens to watch a device they just connected is exactly wrong.
    @AppStorage("com.loom.sidebar.collapsedDevices") private var collapsedDevicesRaw = ""
    private var collapsedDevices: Set<String> {
        get { Set(collapsedDevicesRaw.split(separator: "\n").map(String.init)) }
        nonmutating set { collapsedDevicesRaw = newValue.sorted().joined(separator: "\n") }
    }
    /// Inspector pane height, set by dragging its top edge. Persisted for the same reason
    /// the section states are: it is view-local chrome nothing else reads, and re-dragging
    /// it on every launch is the annoyance.
    @AppStorage("com.loom.inspector.height") private var inspectorHeight = 280.0
    /// Height at the start of a divider drag — nil when no drag is in flight.
    @State private var dragStartHeight: CGFloat?
    /// Live height while a drag is in flight; `inspectorHeight` is the resting value.
    @State private var dragHeight: CGFloat?

    /// DESIGN.md: sidebar-width 300, fixed. One constant because two consumers have to
    /// agree on it — the sidebar's own frame and the toolbar chip's centring offset (see
    /// `toolbarContent`). Drift between them shows as a chip off-centre by half the
    /// disagreement.
    private static let sidebarWidth: CGFloat = 300

    /// Floor for either pane of the table/inspector split.
    private static let minPaneHeight: CGFloat = 160

    public init(store: StoreOf<AppFeature>) {
        self.store = store
    }

    /// A plain `HStack`, and each of the alternatives was tried on this exact view before
    /// settling here:
    ///
    /// - `NavigationSplitView` must never come back: a sidebar-category switch re-diffs the
    ///   whole request table with every row realized (row hosting views accumulate under
    ///   live tail-follow), and AppKit's per-view KVO teardown is quadratic in that count —
    ///   8.7 s vs 143 ms, measured (CLAUDE.md § Known Issues).
    /// - `HSplitView` is a bare `NSSplitView`: no collapse semantics, so there is no
    ///   `isCollapsed` to animate and the sidebar could only be inserted and removed, which
    ///   pops. Its divider was already fixed and undraggable here, so it was buying nothing.
    /// - An `NSSplitViewController` bridge is the only way to get AppKit's own sidebar — its
    ///   drawer animation and the system `.toggleSidebar` toolbar item — but on macOS 26 a
    ///   `.sidebar` split item is a floating glass card: measured
    ///   `NSContainerConcentricGlassEffectView f=(8,8,300,821)` in an 869pt-tall pane, i.e.
    ///   8pt margins and **40pt off the top** (32pt titlebar + its own 8). The pane is full
    ///   height and the window carries `.fullSizeContentView`, so that inset is the card's
    ///   own, placed by an AppKit constraint (`wrapper.top == card.top - 40`); overriding
    ///   the frame is undone next layout, and changing that constraint's constant had no
    ///   effect. Owner's call: keep the flush sidebar, hand-roll the collapse.
    ///
    /// So the collapse animates the pane's *width* — a real push, not an insertion.
    public var body: some View {
        HStack(spacing: 0) {
            sidebar
                // The inner frame pins the content at full width; the outer one animates.
                // Trailing alignment is what makes it a push: at width 0 the content sits
                // entirely off the leading edge and slides in as the box grows, instead of
                // squashing from 300pt to nothing.
                .frame(width: Self.sidebarWidth)
                .overlay(alignment: .trailing) { Divider() }
                .frame(width: sidebarVisible ? Self.sidebarWidth : 0, alignment: .trailing)
                .clipped()
            content
                .toolbar { toolbarContent }
                .frame(minWidth: 480, maxWidth: .infinity, maxHeight: .infinity)
        }
        // The lighter band that used to sit across the window's top was macOS 26's scroll
        // edge effect: AppKit draws an `NSScrollPocket` at the top of every scroll view
        // meeting that edge — measured `f=(0,0,1160,80)` over the table and `f=(0,0,300,52)`
        // over the sidebar, whose visible `BackdropView` is what showed. Nothing at this
        // layer removed it. Ruled out by measurement, in order: the titlebar's own fill
        // (`NSTitlebarBackgroundView` is already hidden by `titlebarAppearsTransparent`, and
        // hiding the remaining titlebar backdrop view changed nothing on screen), the
        // toolbar item's shared glass, and SwiftUI's `scrollEdgeEffectHidden(true, for: .top)`
        // — which leaves the pocket's backdrop visible on these AppKit-backed scroll views.
        // AppKit's own `NSScrollEdgeEffectStyle` is macOS 26.1 and settable only on split-view
        // and titlebar *accessory* controllers, not on `NSScrollView`.
        //
        // What did remove it is `UIDesignRequiresCompatibility` in the app's Info.plist
        // (`Project.swift`), which puts the whole app back in the pre-26 system design that
        // DESIGN.md specifies. Keep that key and this band stays gone; drop it and every dead
        // end above is live again — so re-read them before trying to fix it per view.
        // Frosts the toolbar band so the request table blurs under the status chip instead
        // of reading crisply through it — see `WindowChrome` for why neither
        // `.toolbarBackground` nor AppKit's own titlebar fill does the job here.
        .background(WindowChrome())
        .task { store.send(.viewAppeared) }
        .sheet(item: $store.scope(state: \.rules.editor, action: \.rules.editor)) { editorStore in
            RuleEditorView(store: editorStore)
        }
    }

    // MARK: Sidebar — categories

    /// A sidebar row's trailing count, drawn directly rather than through
    /// `.badge()`.
    ///
    /// `.badge` gives AppKit's pill treatment, which is right for "N unread things
    /// demanding attention" and wrong for every count here — these are just how
    /// many flows are in a bucket, on every row at once, and a column of pills
    /// reads as a column of alerts. Plain tertiary digits sit back where they
    /// belong. Monospaced so a count crossing 9→10→100 doesn't shift the row.
    /// `tint` is for the ONE bucket whose name is itself a fault. Every other count
    /// here is a bucket size — how many flows, how many rules — and tinting those
    /// would turn the column into a row of alerts, which is the exact reason these
    /// are plain digits and not `.badge()` pills (see `countedRow`).
    private func sidebarCount(_ count: Int, tint: Color? = nil) -> some View {
        Text("\(count)")
            .font(.callout.monospacedDigit())
            .foregroundStyle(tint.map(AnyShapeStyle.init) ?? AnyShapeStyle(.tertiary))
    }

    /// `Label` + a trailing count, the shape every sidebar row now uses.
    private func countedRow<Title: View, Icon: View>(
        count: Int,
        countTint: Color? = nil,
        @ViewBuilder title: () -> Title,
        @ViewBuilder icon: () -> Icon
    ) -> some View {
        Label {
            HStack(spacing: LoomTheme.Space.xs) {
                title()
                Spacer(minLength: LoomTheme.Space.xs)
                sidebarCount(count, tint: countTint)
            }
        } icon: {
            icon()
        }
    }

    private var sidebar: some View {
        // A `Set` selection, so ⌘-click and ⇧-click compose filters the way they do
        // in every other Mac list. What a set of them *means* is Loom's
        // (`FlowCategory.Dimension`); what is allowed in one is normalized in the
        // reducer, not here — a view that filtered the set would be a second place
        // the rules live.
        List(selection: $store.capture.selection.sending(\.capture.categoriesSelected)) {
            countedRow(count: store.capture.allCount) { Text("All Flows") } icon: { categoryIcon("tray.full") }
                .tag(FlowCategory.all)
            // The only tinted count in the sidebar: a non-zero Errors bucket is the one
            // number here that is a fault rather than a size, and it is the number a
            // human opens this window to check.
            countedRow(count: store.capture.errorCount,
                       countTint: store.capture.errorCount > 0 ? LoomTheme.Palette.error : nil) { Text("Errors") } icon: { categoryIcon("exclamationmark.triangle") }
                .tag(FlowCategory.errors)
            countedRow(count: store.rules.rulesState.rules.count) { Text("Rules") } icon: { categoryIcon("wand.and.stars") }
                .tag(FlowCategory.rules)
            countedRow(count: store.audit.entries.count) { Text("Audit") } icon: { categoryIcon("checklist") }
                .tag(FlowCategory.audit)
            breakpointsSidebarRow

            if !store.capture.devices.isEmpty {
                Section {
                    // The Devices and Apps sections used to sit side by side, and
                    // that made the same flow appear in two unrelated buckets with
                    // no way to say "this app, on this device". They are one tree
                    // now: a device is a group, its apps are its children.
                    ForEach(devicesExpanded ? store.capture.devices : []) { entry in
                        deviceRows(entry)
                    }
                } header: {
                    SidebarSectionHeader(
                        title: "Devices", count: store.capture.devices.count, expanded: $devicesExpanded
                    )
                }
            }

            Section {
                ForEach(hostsExpanded ? store.capture.hosts : [], id: \.host) { entry in
                    let pinned = store.capture.pinnedHosts.contains(entry.host)
                    countedRow(count: entry.count) {
                        rowTitle(entry.host, pinned: pinned)
                    } icon: {
                        FaviconView(host: entry.host)
                    }
                    .tag(FlowCategory.host(entry.host))
                    .contextMenu {
                        Button(pinned ? "Unpin" : "Pin", systemImage: pinned ? "pin.slash" : "pin") {
                            store.send(.capture(.pinHostToggled(entry.host)))
                        }
                    }
                }
            } header: {
                SidebarSectionHeader(
                    title: "Hosts", count: store.capture.hosts.count, expanded: $hostsExpanded
                )
            }
        }
        .listStyle(.sidebar)
        // Width is applied by `body`, which animates exactly that value on collapse; this
        // only needs to fill vertically. (`navigationSplitViewColumnWidth` is a no-op
        // outside `NavigationSplitView`, and the divider is deliberately not draggable.)
        .frame(maxHeight: .infinity)
    }

    /// One device and, folded under it, the apps seen on it.
    ///
    /// A flat pair of rows rather than a `DisclosureGroup`, and that is a
    /// `List(selection:)` constraint rather than a style preference: a
    /// `DisclosureGroup`'s label is not a selectable row, so the device itself
    /// would stop being clickable — and selecting a device (all of its traffic) is
    /// the more common of the two things this tree is for. The chevron lives in the
    /// device row and the children are indented siblings, which is also how the
    /// section headers here already work (see `SidebarSectionHeader`).
    @ViewBuilder private func deviceRows(_ entry: CaptureFeature.State.DeviceRow) -> some View {
        let ip = entry.device.groupingKey
        let alias = store.capture.deviceAliases[ip]
        let collapsed = collapsedDevices.contains(ip)
        countedRow(count: entry.count) {
            HStack(spacing: LoomTheme.Space.xxs) {
                Text(alias ?? entry.device.displayName)
                Spacer(minLength: 0)
                if !entry.apps.isEmpty {
                    deviceDisclosure(ip: ip, collapsed: collapsed, appCount: entry.apps.count)
                }
            }
        } icon: {
            categoryIcon(Self.deviceGlyph(entry.device))
        }
        .tag(FlowCategory.device(ip))
        .help(entry.device.typeSummary.map { "\($0) · \(entry.device.ip)" } ?? entry.device.ip)
        .contextMenu {
            Button(alias == nil ? "Set Alias…" : "Rename…", systemImage: "pencil") {
                promptDeviceAlias(ip: ip, current: alias ?? "")
            }
            if alias != nil {
                Button("Clear Alias", systemImage: "xmark.circle") {
                    store.send(.capture(.setDeviceAlias(ip: ip, alias: nil)))
                }
            }
        }

        if !collapsed {
            ForEach(entry.apps) { app in
                let key = app.app.groupingKey
                let pinned = store.capture.pinnedApps.contains(key)
                countedRow(count: app.count) {
                    rowTitle(app.app.name, pinned: pinned)
                } icon: {
                    AppIconView(app: app.app)
                }
                .tag(FlowCategory.app(device: ip, key: key))
                // The indent is the only thing saying this row belongs to the
                // device above it, since these are siblings in the list.
                .padding(.leading, LoomTheme.Space.md)
                .help(app.app.attribution == .userAgent
                      ? "\(app.app.name) — identified from its User-Agent"
                      : app.app.name)
                .contextMenu {
                    Button(pinned ? "Unpin" : "Pin", systemImage: pinned ? "pin.slash" : "pin") {
                        store.send(.capture(.pinAppToggled(key)))
                    }
                }
            }
        }
    }

    /// The fold control on a device row. A plain button rather than the row's own
    /// tap, because the row already means "select this device's traffic" and one
    /// gesture cannot honestly mean both.
    private func deviceDisclosure(ip: String, collapsed: Bool, appCount: Int) -> some View {
        Button {
            var next = collapsedDevices
            if collapsed { next.remove(ip) } else { next.insert(ip) }
            collapsedDevices = next
        } label: {
            SidebarDisclosureChevron(expanded: !collapsed)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(collapsed ? "Show apps" : "Hide apps")
        .help(collapsed ? "Show \(appCount) app\(appCount == 1 ? "" : "s")" : "Hide apps")
    }

    /// The glyph for a device row. Android gets Loom's own symbol — SF Symbols has
    /// no Android mark, and drawing every non-Apple device as `iphone` is the kind
    /// of small lie that makes a sidebar harder to scan, not easier.
    static func deviceGlyph(_ device: SourceDevice) -> String {
        guard device.kind == .lan else { return "desktopcomputer" }
        switch device.platform {
        case "Android": return "loom.device.android"
        case "iPadOS": return "ipad"
        case "iOS": return "iphone"
        case "macOS": return "laptopcomputer"
        case "Windows", "Linux", "ChromeOS": return "pc"
        default: return "iphone"
        }
    }

    /// A sidebar category glyph. `.listStyle(.sidebar)` tints a `Label`'s symbol with the
    /// system accent, which reads as a highlight on every row at once — so these are drawn
    /// monochrome/secondary and selection is left to say what's selected. The only glyph
    /// allowed to carry color is the held-breakpoint one, which is an alert, not a category.
    @ViewBuilder private func categoryIcon(_ name: String) -> some View {
        // A custom symbol lives in the asset catalog and is addressed by name, not
        // through `systemName` — which does not fall back, it just yields nothing.
        // One prefix decides it, so a caller passes a name and never a flag.
        (name.hasPrefix("loom.") ? Image(name) : Image(systemName: name))
            .symbolRenderingMode(.monochrome)
            .foregroundStyle(.secondary)
    }

    /// Breakpoints category. While something is held the row goes orange and its
    /// count is of *held exchanges*, not armed breakpoints — a parked live
    /// connection is the thing the human has to act on; how many breakpoints an
    /// agent armed is only interesting when none of them is holding anything.
    ///
    /// The title is tinted **only** while something is held, and says nothing at all
    /// otherwise — `.foregroundStyle(.primary)` is not "the default". Every other row
    /// here leaves its `Text` unstyled, so all of them dim together when the window
    /// stops being key; naming a style, even the one that looks like the default, opts
    /// that row out of the dimming, and Breakpoints alone stayed at full contrast in an
    /// unfocused window — reading as an alert on a row with nothing to report.
    private var breakpointsSidebarRow: some View {
        let held = store.breakpoints.heldCount
        return countedRow(count: held > 0 ? held : store.breakpoints.armed.count) {
            breakpointsTitle(held: held)
        } icon: {
            Image(systemName: held > 0 ? "pause.circle.fill" : "pause.circle")
                .symbolRenderingMode(.monochrome)
                .foregroundStyle(held > 0 ? LoomTheme.Palette.warning : .secondary)
                .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace))
        }
        .tag(FlowCategory.breakpoints)
        .help(held > 0
            ? "\(held) exchange\(held == 1 ? "" : "s") held — the client is still waiting"
            : "Breakpoints armed by your agent")
    }

    /// The Breakpoints title, tinted only when there is something held. Split out
    /// because "apply no style" and "apply the default style" are different views and
    /// only a `@ViewBuilder` branch can say the first one.
    @ViewBuilder private func breakpointsTitle(held: Int) -> some View {
        if held > 0 {
            Text("Breakpoints").foregroundStyle(LoomTheme.Palette.warning)
        } else {
            Text("Breakpoints")
        }
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
        // The find bar is a **row in this stack**, not a `safeAreaInset`.
        //
        // As an inset it changed the table's safe area, which AppKit turns into a
        // scroll-view content inset outside SwiftUI's animation transaction: the
        // bar slid while `NSTableHeaderView` jumped to its new position, so the two
        // read as unrelated. In the stack, the table's *frame* is what changes, and
        // a representable's frame is set by SwiftUI on every tick of the animation
        // — header, rows and bar move as one.
        VStack(spacing: 0) {
            if store.capture.search.isPresented {
                FlowFilterBar(store: captureStore)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            Group {
                // O(1) aggregate probe — `displayFlows.isEmpty` would filter the whole
                // window a second time per render just to pick the empty state.
                if store.capture.displayFlowsAreEmpty {
                    emptyState.frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    RequestTableView(store: captureStore, followTail: $followTail)
                        // The clear control floats over the table (bottom-right): a small red
                        // dot at rest, expanding to the full hold-to-clear button on hover, so
                        // it barely covers content until you reach for it. No reserved gap —
                        // the table keeps full height and the row stripes fill it.
                        .safeAreaInset(edge: .bottom, spacing: 0) {
                            if store.capture.droppedFlowCount > 0 { capBanner }
                        }
                        .overlay(alignment: .bottomTrailing) { clearFAB }
                }
            }
        }
        // Scoped to the bar's presence: a blanket `.animation` here would also
        // animate the table's own updates, which arrive ten times a second under
        // capture.
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: store.capture.search.isPresented)
        // The bar slides out of the toolbar band it hangs from; without this it
        // paints over the band on the way in.
        .clipped()
    }

    /// Honest "you're not seeing everything" strip: the session cap has dropped
    /// the oldest flows, so a huge capture doesn't masquerade as complete.
    private var capBanner: some View {
        HStack(spacing: LoomTheme.Space.xs) {
            Image(systemName: "clock.arrow.circlepath").font(.caption2)
            Text("Showing the latest \(CaptureFeature.State.displayCap) · \(store.capture.droppedFlowCount) older cleared")
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
                        .stroke(LoomTheme.Palette.error, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        .rotationEffect(.degrees(-90)) // start the fill at 12 o'clock
                        .padding(3)
                    Image(systemName: "trash")
                        .font(LoomTheme.Icon.fab)
                        .foregroundStyle(LoomTheme.Palette.error)
                }
                // Grow out of the dot: scale up from the corner + fade in.
                .transition(.scale(scale: 0.3, anchor: .bottomTrailing).combined(with: .opacity))
            } else {
                Circle()
                    .fill(LoomTheme.Palette.error)
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
            store.send(.capture(.clearTapped))
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

    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }


    // MARK: Content — table only, or table + inspector when a flow is selected

    @ViewBuilder private var content: some View {
        if store.capture.panelCategory == .rules {
            RulesPanelView(store: store.scope(state: \.rules, action: \.rules))
        } else if store.capture.panelCategory == .audit {
            AuditPanelView(store: store.scope(state: \.audit, action: \.audit))
        } else if store.capture.panelCategory == .breakpoints {
            BreakpointsPanelView(store: store.scope(state: \.breakpoints, action: \.breakpoints))
        } else {
            flowArea
        }
    }

    /// Request table on top, inspector below when a flow is selected.
    ///
    /// Not a `VSplitView`, for the same reason the sidebar's collapse is hand-rolled
    /// (see `body`): an `NSSplitView` inserts and removes its subviews outright, so the
    /// inspector could only pop in and out. Here it slides — the panel carries a
    /// `.move(edge: .bottom)` transition and the stack is clipped, so it travels up from
    /// the window's bottom edge and back down out of it while the table resizes with it.
    /// The draggable divider is hand-rolled below, which is all `VSplitView` was buying.
    private var flowArea: some View {
        GeometryReader { proxy in
            // The table keeps at least a pane's worth no matter how far the divider is
            // dragged, and a short window shrinks the inspector rather than the table.
            let maxInspector = max(Self.minPaneHeight, proxy.size.height - Self.minPaneHeight)
            VStack(spacing: 0) {
                requestArea
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if let flow = store.capture.selectedFlow {
                    VStack(spacing: 0) {
                        inspectorDivider(maxHeight: maxInspector)
                        InspectorPanel(
                            // The hydrated detail (with bodies) once it lands; the
                            // metadata-only list row until then, so the panel appears
                            // immediately and its body fills in.
                            flow: store.capture.selectedFlowDetail ?? flow,
                            original: store.capture.selectedOriginalDetail,
                            onClose: { store.send(.capture(.flowSelected(nil))) }
                        )
                        .frame(height: min(
                            max(dragHeight ?? CGFloat(inspectorHeight), Self.minPaneHeight),
                            maxInspector
                        ))
                    }
                    .transition(.move(edge: .bottom))
                }
            }
            // Bounds the slide: without it the panel is drawn outside the pane on its way
            // in and out instead of being revealed by the window's bottom edge.
            .clipped()
            // Keyed on *whether* a flow is selected, never on which one: switching rows
            // must not re-run the slide, and a divider drag must not be animated at all.
            .animation(.snappy(duration: 0.22), value: store.capture.selectedFlowID == nil)
        }
    }

    /// The inspector's top edge, doubling as its resize handle. `.snappy` never sees these
    /// height writes (see the animation note above), so the drag tracks the cursor 1:1.
    ///
    /// Two things here are what stop it juddering, and both are the same feedback loop:
    /// the handle is *inside* the thing it resizes, so anything that measures against the
    /// handle's own frame is measuring a moving ruler. Hence `.global` — a local
    /// `translation` is re-based every time the divider moves under the cursor, which
    /// reads as the panel fighting the drag. And hence `dragHeight`: `@AppStorage` is the
    /// resting value only, because writing it per frame round-trips every height through
    /// `UserDefaults` and its change notification lands a frame late.
    private func inspectorDivider(maxHeight: CGFloat) -> some View {
        Divider()
            // Widens the hit target without moving the hairline.
            .padding(.vertical, 2)
            .contentShape(.rect)
            .onHover { inside in
                if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
            }
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { drag in
                        let start = dragStartHeight ?? CGFloat(inspectorHeight)
                        dragStartHeight = start
                        // Dragging up (negative translation) grows the inspector.
                        dragHeight = min(
                            max(start - drag.translation.height, Self.minPaneHeight), maxHeight
                        )
                    }
                    .onEnded { _ in
                        if let settled = dragHeight { inspectorHeight = Double(settled) }
                        dragHeight = nil
                        dragStartHeight = nil
                    }
            )
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
            store.send(.capture(.setDeviceAlias(ip: ip, alias: value.isEmpty ? nil : value)))
        }
    }

    /// Phone/QR onboarding entry, right of the toolbar's ip:port chip.
    private var deviceReadiness: DeviceReadiness {
        DeviceReadiness(isRunning: store.status.isRunning, lanEnabled: store.lanEnabled)
    }

    private var phoneButton: some View {
        Button {
            store.send(.phoneButtonTapped(.mainWindow))
        } label: {
            Image(systemName: deviceReadiness.symbol)
                // Highlighted while a phone could actually reach Loom; secondary
                // otherwise, whether that is because LAN capture is off or because
                // the proxy isn't listening.
                .foregroundStyle(deviceReadiness.isReady ? LoomTheme.Palette.accent : .secondary)
                .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace))
        }
        .buttonStyle(.borderless)
        .disabled(!store.status.isRunning)
        .accessibilityLabel("Connect Device")
        .accessibilityValue(deviceReadiness.help)
        .help(deviceReadiness.help)
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
        // Hand-rolled, and it has to be: AppKit's `.toggleSidebar` item sends
        // `toggleSidebar(_:)` down the responder chain, and only `NSSplitViewController`
        // answers it — the container this view deliberately doesn't use (see `body`). Same
        // glyph as the system item, and the standard ⌃⌘S.
        ToolbarItem(placement: .navigation) {
            Button(action: toggleSidebar) {
                Image(systemName: "sidebar.left")
            }
            .keyboardShortcut("s", modifiers: [.control, .command])
            .accessibilityLabel(sidebarVisible ? "Hide Sidebar" : "Show Sidebar")
            .help(sidebarVisible ? "Hide Sidebar" : "Show Sidebar")
        }
        ToolbarItem(placement: .principal) {
            statusChip
        }
    }

    /// Both the button and ⌃⌘S land here, so the animation is stated once. `.snappy` rather
    /// than a longer spring: the slide resizes the content pane every frame and the request
    /// table relayouts with it, so a long animation makes that visible at a full ring.
    private func toggleSidebar() {
        withAnimation(.snappy(duration: 0.2)) {
            sidebarVisible.toggle()
        }
    }

    /// The status chip: capture dot + address, then the state toggles. Extracted only so
    /// `toolbarContent` stays readable; the toolbar item draws its own background.
    ///
    /// It centres on the *window*, not on the content pane, because that is what
    /// `.principal` does. Two ways to shift it onto the pane were tried and both cost more
    /// than they fix: padding the item's leading edge by a sidebar width stretches the
    /// shared-glass capsule by the same 300pt, and hiding that shared background to draw
    /// the capsule here leaves the toolbar rendering a full-width backdrop instead. (The
    /// capsule itself is gone now that the app renders in the pre-26 design — see
    /// `UIDesignRequiresCompatibility` in `Project.swift` — but window-centring is
    /// `.principal`'s own behavior in both designs, so this note still applies.)
    private var statusChip: some View {
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

            // Shown even while the proxy is stopped — see `DeviceReadiness`. It
            // used to be hidden, which removed the control precisely when someone
            // was looking for why their phone couldn't connect.
            phoneButton

            Divider().frame(height: 14)

            // Same split as the console's strip, and for the same reasons: the
            // system proxy is the async one, so it pulses and does not morph (the
            // `globe` family has no honest on/off pair — see PanelView); the two
            // local toggles morph, because they flip instantly and a `.replace`
            // needs two symbols to be a transition between.
            statusIcon("globe", on: store.setup.isSystemProxy,
                       busy: store.setup.systemProxyBusy,
                       help: store.setup.isSystemProxy ? "System proxy: on" : "System proxy: off") {
                store.send(.setup(.toggleSystemProxyTapped))
            }
            sslButton
            statusIcon(store.rules.rulesEnabled ? "wand.and.stars.inverse" : "wand.and.stars",
                       on: store.rules.rulesEnabled,
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

    /// green = proxy up & recording · yellow = up but recording paused · grey = off.
    private var captureDotColor: Color {
        guard store.status.isRunning else { return .secondary }
        return store.isRecording ? LoomTheme.Palette.success : LoomTheme.Palette.waiting
    }

    /// Start/stop capture. Idle shows a circular record symbol; recording shows a
    /// stop glyph. Text label kept ("Record"/"Stop").
    private var recordButton: some View {
        Button { store.send(.toggleRecordingTapped) } label: {
            HStack(spacing: 5) {
                Image(systemName: store.isRecording ? "stop.fill" : "record.circle")
                    .font(LoomTheme.Icon.toolbar)
                    .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace))
                Text(store.isRecording ? "Stop" : "Record")
                    .font(.callout)
            }
            .foregroundStyle(store.isRecording ? LoomTheme.Palette.warning : LoomTheme.Palette.error)
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
    /// normal on/off toggle (accent when on).
    private var sslButton: some View {
        let needsTrust = store.setup.sslEnabled && !store.setup.certificateStatus.trustState.isReady
        return Button {
            if needsTrust { showingCertTrust = true }
            else { store.send(.setup(.toggleSSLTapped)) }
        } label: {
            // Filled while interception is on — including the needs-trust state,
            // which really is on and is said by the yellow, not by an outline.
            Image(systemName: store.setup.sslEnabled ? "lock.shield.fill" : "lock.shield")
                .font(LoomTheme.Icon.toolbar)
                .foregroundStyle(needsTrust ? LoomTheme.Palette.waiting : (store.setup.sslEnabled ? LoomTheme.Palette.accent : Color.secondary))
                .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace))
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

    /// A chip toggle. `busy` drives the same repeating pulse the console's tiles
    /// use — this window and that panel are two renderings of one state, so an
    /// in-flight write has to look in-flight on both; a toggle that only animates
    /// on one surface teaches the reader that the other one is frozen.
    private func statusIcon(
        _ symbol: String,
        on: Bool,
        busy: Bool = false,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(LoomTheme.Icon.toolbar)
                // ON is the accent, not green — the console's switch-tiles say "on"
                // that way (DESIGN.md § switch-tile), and this window and that panel
                // are two renderings of one state. It also hands green back to the
                // status classes, which are the only place it means something
                // specific: three toolbar toggles wearing 2xx-green is what made the
                // color stop reading as a status at all.
                .foregroundStyle(on ? LoomTheme.Palette.accent : Color.secondary)
                .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace))
                .symbolEffect(.pulse, options: .repeating, isActive: busy && !reduceMotion)
                .frame(width: 30, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .disabled(busy)
        .accessibilityLabel(help)
        .accessibilityValue(busy ? "changing" : (on ? "on" : "off"))
        .help(help)
    }

    @ViewBuilder private var emptyState: some View {
        if store.capture.search.isActive {
            // "No matches" and "no traffic" must not read the same — an empty filtered
            // list otherwise sends someone to debug their client instead of their
            // needle. What each scope actually covered differs, so the two are worded
            // apart rather than sharing one half-true sentence: the engine scopes read
            // through to stored history, the URL scope filters this window's own rows.
            ContentUnavailableView {
                Label("No matching requests", systemImage: "line.3.horizontal.decrease")
            } description: {
                if store.capture.search.scope.needsEngine {
                    Text("""
                    Nothing in the stored capture matches “\(store.capture.search.text)” in \
                    \(store.capture.search.scope.label.lowercased()). Exchanges pruned past the \
                    store's row cap aren't searched.
                    """)
                } else {
                    Text("""
                    Nothing in the latest \(CaptureFeature.State.displayCap) captured flows \
                    matches “\(store.capture.search.text)” in the URL. Older traffic is still \
                    stored — search its headers or body, or ask an agent.
                    """)
                }
            } actions: {
                Button("Clear Filter") { store.send(.capture(.searchDismissed)) }
            }
        } else if store.capture.allCount > 0 {
            // The capture is not empty — the *selection* admits none of it. Saying
            // "waiting for traffic" here is the same failure the search branch above
            // exists to prevent, and multi-select makes it routine rather than rare:
            // two rows from different groups intersect to nothing far more easily
            // than one row ever did, and the honest message is the one that names
            // what was picked and offers the way out.
            ContentUnavailableView {
                Label("No requests in this selection", systemImage: "line.3.horizontal.decrease")
            } description: {
                Text(
                    "Nothing captured matches \(selectionSummary). Picking more rows in the "
                        + "same group widens the list; picking rows in different groups narrows it."
                )
            } actions: {
                Button("Show All Flows") { store.send(.capture(.categoriesSelected([.all]))) }
            }
        } else if store.status.isRunning {
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

    /// The selected filters, named the way the sidebar names them.
    ///
    /// Resolved through the sidebar rows rather than printed from the category's
    /// own payload: those carry an IP and a bundle key, and telling someone their
    /// selection is `192.168.1.9 + com.example.wallet` when the rows they clicked
    /// said `iOS .238` and `Wallet` is a worse answer than none.
    private var selectionSummary: String {
        let names = store.capture.selection.compactMap { category -> String? in
            switch category {
            case .errors: "Errors"
            case let .host(host): host
            case let .device(ip): deviceName(ip) ?? ip
            case let .app(device, key): appName(device: device, key: key) ?? key
            case .all, .rules, .audit, .breakpoints: nil
            }
        }
        // Joined with "+" rather than "and"/"or": which one it is depends on whether
        // the two rows share a group, and a summary that picked one word would be
        // wrong half the time. The sentence after it explains the rule instead.
        return names.sorted().joined(separator: " + ")
    }

    private func deviceName(_ ip: String) -> String? {
        guard let row = store.capture.devices.first(where: { $0.device.groupingKey == ip }) else {
            return nil
        }
        return store.capture.deviceAliases[ip] ?? row.device.displayName
    }

    private func appName(device: String, key: String) -> String? {
        store.capture.devices
            .first { $0.device.groupingKey == device }?
            .apps.first { $0.app.groupingKey == key }?
            .app.name
    }

    /// Both go through `URLHost`, which exists for exactly this call site: a row
    /// body runs per visible row per redraw, and these used to build a
    /// `URLComponents` each time — the cost `Flow.host` and the sidebar's host
    /// filter were already moved off. Cache the result per row rather than calling
    /// twice for the same string.
    static func host(_ raw: String) -> String { URLHost.host(ofURLString: raw) ?? raw }
    static func path(_ raw: String) -> String { URLHost.pathAndQuery(ofURLString: raw) }

    /// The Protocol column's token. Deliberately the *scheme* — the thing that decides
    /// whether these bytes were readable at all — and not `response.httpVersion`, which
    /// describes Loom's own upstream hop (`NIOStreamingForwarder` speaks HTTP/1.1, so it
    /// reads "HTTP/1.1" even for a client that negotiated h2 and would be a lie in this
    /// column). A prefix scan, never `URLComponents`: this runs per visible row per redraw.
    static func protocolLabel(_ flow: Flow) -> String {
        let raw = flow.request.url
        guard let separator = raw.range(of: "://") else { return flow.isWebSocket ? "WS" : "—" }
        let scheme = raw[raw.startIndex ..< separator.lowerBound].uppercased()
        // A WebSocket is captured on the URL it was *upgraded* from, so an https:// row
        // that carries frames is a wss:// connection and says so.
        guard flow.isWebSocket else { return scheme }
        return scheme == "HTTPS" || scheme == "WSS" ? "WSS" : "WS"
    }

    /// The Host column needs the grouping key *and* the port-bearing label; one
    /// scan yields both. A string that isn't a URL shows whole, same as `host(_:)`.
    static func hostReading(_ raw: String) -> URLHost.HostReading {
        URLHost.hostReading(ofURLString: raw) ?? URLHost.HostReading(key: raw, label: raw)
    }
}

// MARK: - Collapsible sidebar section header

/// Header for one of the sidebar's grouping sections (Devices / Apps / Hosts).
///
/// Hand-rolled rather than `Section(isExpanded:)`, and the reason is the chevron:
/// AppKit's own sidebar disclosure triangle is a *hover* control with no opt-out —
/// it appears only under the cursor, so which sections are collapsible is invisible
/// at rest. Owning the header means the chevron is always drawn (rotating in place
/// rather than swapping glyphs, so the state change reads as one motion), and it also
/// means the whole header is the hit target: AppKit made only the triangle itself
/// clickable, a few points wide, and the label beside it inert.
///
/// The count is shown only while the section is folded. Collapsed, the rows were the
/// only thing saying how many devices/apps/hosts the capture has seen, and a section
/// hiding an unknown number of them is exactly the silent-truncation shape CLAUDE.md
/// rules out. Expanded, each row carries its own badge and a total on the header is
/// noise. It sits just inside the chevron rather than flush to the window edge, which
/// is where `.badge()` on a header put it.
/// The sidebar's one disclosure chevron — a section header's and a device row's.
///
/// Shared rather than written twice, because the two sat two rows apart and drew
/// differently (a heavier `.secondary` down-chevron over a lighter `.tertiary`
/// right-chevron), which read as two different kinds of control rather than one
/// control at two levels of a tree.
///
/// One glyph rotated, never two glyphs swapped: the chevron turns through the
/// state change instead of popping.
struct SidebarDisclosureChevron: View {
    let expanded: Bool

    var body: some View {
        Image(systemName: "chevron.right")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.tertiary)
            .rotationEffect(.degrees(expanded ? 90 : 0))
            // Fixed, so a row's other content does not shift as it turns.
            .frame(width: 10)
    }
}

private struct SidebarSectionHeader: View {
    let title: String
    let count: Int
    @Binding var expanded: Bool

    /// Trailing inset for the chevron, mirroring where `List` insets the rows' own
    /// badges (it gives no way to read that value back, so this is measured by hand —
    /// if a future macOS changes the row inset, this is the one number to re-check).
    /// The count then sits just inside the chevron rather than flush to the window
    /// edge, which is where `.badge()` on a header put it.
    private static let trailingInset: CGFloat = 12

    var body: some View {
        HStack(spacing: LoomTheme.Space.xs) {
            Text(title)
            Spacer(minLength: LoomTheme.Space.xxs)
            if !expanded {
                Text(count, format: .number)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            // Trailing, where AppKit's own hover triangle sat — the position the
            // native sidebar trains you to look at. Always drawn, so which sections
            // fold is visible without hunting with the cursor.
            SidebarDisclosureChevron(expanded: expanded)
        }
        .padding(.trailing, Self.trailingInset)
        // The hit target is the whole header, not just the glyph. `contentShape`
        // is what makes the gaps between title, spacer and count tappable too —
        // without it only the drawn pixels respond.
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.2)) { expanded.toggle() }
        }
        .help(expanded
            ? "Collapse \(title)"
            : "Show \(count) \(count == 1 ? String(title.dropLast()) : title)")
    }
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

/// The request table, its own view rather than a computed property of `MainView`.
///
/// As part of `MainView.body` it shared that view's observation: every store property
/// read anywhere in the window — an audit entry arriving, a rule refresh, a breakpoint
/// tick, proxy status, update availability — invalidated the table too, and re-running
/// the table body makes SwiftUI re-diff every row. Here it reads only what it draws.
private struct RequestTableView: View {
    @Bindable var store: StoreOf<CaptureFeature>
    /// Tail-follow lives in `MainView`, alongside the empty state and clear button
    /// that share it; the table below consumes it.
    @Binding var followTail: Bool

    var body: some View {
        // Both read once here, not per row: a cell body that touches `store.flows`
        // makes every realized row *observe* the whole capture, so one live batch
        // invalidates all of them. Handed down as plain values, the dependency belongs
        // to this view.
        let rows = store.displayFlows
        let capture = store.flows
        return RequestTable(
            rows: rows,
            capture: capture,
            selection: $store.selectedFlowID.sending(\.flowSelected),
            followTail: $followTail,
            onReplay: { store.send(.replayTapped($0)) },
            onCopyCurl: { store.send(.copyCurlTapped($0)) },
            onAddRule: { store.send(.addRuleFromFlow($0, $1)) }
        )
        // Selection is an interactive signal, so it is the accent's job (DESIGN.md
        // § Colors) — untinted, `NSTableView` fills the row with the *system* accent, a
        // hue the user sets and Loom's is not, right next to accent-tinted method glyphs
        // and toolbar toggles.
        .tint(LoomTheme.Palette.accent)
    }
}

/// Gives the toolbar band a frosted-glass backing, because `.windowStyle(.hiddenTitleBar)`
/// (LoomApp) leaves it painting *nothing*: it sets `titlebarAppearsTransparent` **and**
/// `.fullSizeContentView`, so the request table extends under the band and its rows read
/// crisply through the status chip.
///
/// Two things were tried first and neither is the fix — don't re-add them:
/// - SwiftUI's `.toolbarBackground(.visible, for: .windowToolbar)` is a no-op under that
///   window style.
/// - Flipping `titlebarAppearsTransparent` back to `false` gives an *opaque* band (AppKit's
///   `NSTitlebarBackgroundView` fill), not a translucent one, whether or not the content
///   extends beneath it.
///
/// So the band is hand-rolled: an `NSVisualEffectView` inserted at the back of the titlebar
/// container. `.withinWindow` blending is the load-bearing part — it samples the content
/// *below it in this window* (the table), which is what makes the rows blur rather than
/// showing through; `.behindWindow` would blur the desktop and ignore the table entirely.
/// It goes in the titlebar container rather than the content view so it sits under the
/// toolbar items (the chip stays crisp) and needs no titlebar-height math.
///
/// The representable itself is zero-size and behind the content — it only exists for the
/// window handle.
private struct WindowChrome: NSViewRepresentable {
    /// Named so a re-apply (window re-key, style change) reuses the one band instead of
    /// stacking a new blur behind the toolbar every pass. (`NSView.tag` is get-only, so the
    /// marker is the identifier.)
    private static let backdropID = NSUserInterfaceItemIdentifier("com.loom.toolbarBackdrop")

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        // The window isn't attached yet in `makeNSView`; apply once it is.
        DispatchQueue.main.async { apply(to: view.window) }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        apply(to: view.window)
    }

    private func apply(to window: NSWindow?) {
        guard let window else { return }
        window.titlebarAppearsTransparent = true
        window.styleMask.insert(.fullSizeContentView)
        window.titleVisibility = .hidden
        // No hairline under the band and no shadow behind it: the frost is the only
        // separation the design wants, so the table reads as one surface sliding under it.
        window.titlebarSeparatorStyle = .none
        window.toolbar?.showsBaselineSeparator = false
        // The titlebar container is reached through a standard window button rather than a
        // private class name: the buttons are documented API and live in exactly that view.
        guard let titlebar = window.standardWindowButton(.closeButton)?.superview else { return }
        guard titlebar.subviews.first(where: { $0.identifier == Self.backdropID }) == nil else { return }
        let backdrop = NSVisualEffectView()
        backdrop.material = .titlebar
        backdrop.blendingMode = .withinWindow
        backdrop.state = .active // keep the frost on when the window loses focus
        backdrop.identifier = Self.backdropID
        // Plain blur: no border, no shadow, nothing that reads as a second edge.
        backdrop.wantsLayer = true
        backdrop.layer?.borderWidth = 0
        backdrop.shadow = nil
        backdrop.translatesAutoresizingMaskIntoConstraints = false
        titlebar.addSubview(backdrop, positioned: .below, relativeTo: titlebar.subviews.first)
        NSLayoutConstraint.activate([
            backdrop.leadingAnchor.constraint(equalTo: titlebar.leadingAnchor),
            backdrop.trailingAnchor.constraint(equalTo: titlebar.trailingAnchor),
            backdrop.topAnchor.constraint(equalTo: titlebar.topAnchor),
            backdrop.bottomAnchor.constraint(equalTo: titlebar.bottomAnchor),
        ])
    }
}
