import AppKit
import ComposableArchitecture
import Foundation
import ProxyClient
import LoomSharedModels
import UpdaterClient

/// Left-sidebar categories in the main window. `.host` groups by domain,
/// `.app` by the originating local app (its bundle id or name).
public enum FlowCategory: Hashable, Sendable {
    case all
    case errors
    /// Not a flow filter: selecting it swaps the detail area for the rules panel.
    case rules
    /// Not a flow filter: swaps the detail area for the write-action audit trail.
    case audit
    /// Not a flow filter: swaps the detail area for held/armed breakpoints — the
    /// one write action that parks a live connection, so it needs a human surface.
    case breakpoints
    case host(String)
    case app(String)
    /// Group by originating device (keyed on remote IP): this Mac or a LAN device.
    case device(String)
}

/// Which surface opened the phone-onboarding popover. The panel and the main
/// window both bind a popover to the single `phone` state, so without this they'd
/// both present at once — each view gates its popover on its own origin.
public enum PhoneOnboardingOrigin: Equatable, Sendable {
    case panel, mainWindow
}

@Reducer
public struct AppFeature: Sendable {
    @ObservableState
    public struct State: Equatable {
        public var status = ProxyStatus(isRunning: false, port: 9090, capturedCount: 0)
        /// Stored oldest-first (insertion order); lists display newest-first.
        public var flows: IdentifiedArrayOf<Flow> = []
        /// Most flows the window keeps in memory this session; older ones are
        /// dropped oldest-first (the engine ring is bounded the same way, so the
        /// list would never surface them anyway). Matches `FlowStore.capacity`.
        public static let displayCap = 2000
        /// How many flows the cap has dropped this session — surfaced in the list
        /// footer so a big capture doesn't *look* like it kept everything.
        public var droppedFlowCount = 0
        public var selectedCategory: FlowCategory? = .all
        public var selectedFlowID: Flow.ID?

        /// Write-action audit trail, newest-first (the sidebar → Audit panel).
        /// Bounded like the flow list so a long session can't grow it unbounded;
        /// the durable store keeps more, surfaced via the `get_audit_log` MCP tool.
        public var auditEntries: IdentifiedArrayOf<AuditEntry> = []
        /// Most audit entries the window keeps in memory this session; the durable
        /// store keeps more, surfaced via the `get_audit_log` MCP tool.
        public static let auditDisplayCap = 500

        // Config surfaced in the status-bar console / toolbar.
        public var localIP: String?             // this machine's LAN IPv4, for display
        /// The M2 setup surface (system proxy, SSL interception, CA trust) — split
        /// into its own feature.
        ///
        /// **Projected, not mirrored.** The child needs the proxy's port and
        /// running state, which the parent owns in `status`. Those two used to be
        /// copied into the child by hand at each place the proxy started, stopped
        /// or failed to start. Those copies were in step — but only because three
        /// separate call sites remembered to write them, and the next path added
        /// would have had to remember too. A stale `proxyRunning` shows the human
        /// a panel offering to route the whole machine at a proxy that isn't
        /// listening, so the cost of forgetting is not cosmetic.
        ///
        /// Filling them in on read from the single source of truth means there is
        /// nothing left to keep in sync.
        public var setup: SetupFeature.State {
            get {
                var setup = setupState
                setup.port = status.port
                setup.proxyRunning = status.isRunning
                return setup
            }
            set {
                // The projected fields are the parent's to own; whatever the child
                // hands back for them is ignored on the next read.
                setupState = newValue
            }
        }

        /// Backing storage for `setup`. Everything the setup feature genuinely owns.
        var setupState = SetupFeature.State()
        /// The traffic-rules surface (rule set, editor, writes) — split into its
        /// own feature. Flow capture/selection/pins stay in the parent.
        public var rules = RulesFeature.State()
        /// Breakpoint supervision (held exchanges + armed breakpoints) — split into
        /// its own feature. Mirrored from the engine; nothing here is persisted.
        public var breakpoints = BreakpointsFeature.State()
        /// Phone-onboarding popover (QR + proxy address + the LAN switch). Non-nil
        /// while shown. Presenting no longer toggles LAN — that's `lanEnabled`.
        @Presents public var phone: PhoneOnboardingFeature.State?
        /// Which surface requested the phone popover, so only that one presents it.
        public var phoneOrigin: PhoneOnboardingOrigin = .mainWindow
        /// Whether LAN device connection runs (proxy on `0.0.0.0` + provisioning
        /// server). Persisted, default on; drives the phone icon's highlight.
        public var lanEnabled = true
        public var isRecording = true            // capture gate — the toolbar Record/Stop button
        /// LAN devices connected to the proxy (excludes this Mac). Connection-derived
        /// (fed by `connectedDeviceCountStream`), so a phone counts the moment it
        /// connects — even if its HTTPS is blind-tunneled and never captured.
        public var connectedDeviceCount = 0
        // Sidebar aggregates, maintained incrementally as flows arrive rather than
        // recomputed by scanning every flow on each render. The scan was four
        // separate O(n) passes per render (hosts / apps / devices / error count) —
        // and the host pass parsed 2000 URLs through `URLComponents` every time.
        var hostCounts: [String: Int] = [:]
        var appCounts: [String: Int] = [:]
        var appReps: [String: SourceApp] = [:]
        var deviceCounts: [String: Int] = [:]
        var deviceReps: [String: SourceDevice] = [:]
        /// Flows that failed or answered 4xx/5xx — the sidebar's Errors badge.
        public var errorCount = 0
        public var pinnedHosts: Set<String> = [] // sidebar hosts pinned to the top
        public var pinnedApps: Set<String> = []  // sidebar apps pinned to the top (by grouping key)
        public var deviceAliases: [String: String] = [:] // user labels for devices, keyed by IP
        /// Auto-update state (Sparkle). `.available` flips the footer button to
        /// its prominent "Update" style; a silent daily probe keeps it fresh.
        public var updateAvailability: UpdateAvailability = .unknown
        var didBoot = false                      // guards the one-shot boot effect

        public var displayHost: String { localIP ?? "127.0.0.1" }

        public init() {}

        /// State already holding `flows`, with the sidebar aggregates in sync.
        /// Assigning `flows` directly would leave the incremental counts empty, so
        /// every path that populates the list — live capture, the boot seed, and
        /// tests — goes through `recordFlow`.
        public init(flows: [Flow]) {
            recordFlows(flows)
        }

        /// Upsert a flow, then enforce the session display cap. Single-flow paths
        /// only — a batch must use `recordFlows`, which trims once at the end:
        /// `IdentifiedArray.removeFirst` shifts the whole backing storage and
        /// rebuilds hash buckets (O(count)), so trimming inside a per-flow loop at
        /// steady-state cap paid O(cap) per genuinely new flow, every 100 ms
        /// window, forever.
        mutating func recordFlow(_ flow: Flow) {
            upsertFlow(flow)
            enforceDisplayCap()
        }

        /// Upsert a whole stream batch, enforcing the display cap once.
        mutating func recordFlows(_ batch: [Flow]) {
            for flow in batch { upsertFlow(flow) }
            enforceDisplayCap()
        }

        /// Upsert without cap enforcement. Every caller must trim afterwards —
        /// go through `recordFlow`/`recordFlows` rather than calling this.
        private mutating func upsertFlow(_ flow: Flow) {
            // Store metadata only — bodies for up to 2000 flows would be a large RAM
            // sink; the inspector hydrates the selected flow's body on demand.
            // An upsert replaces: retract the previous version's contribution to the
            // aggregates first, or a pending→completed update double-counts.
            if let previous = flows[id: flow.id] { retract(previous) }
            let stripped = flow.strippingBodies()
            flows[id: flow.id] = stripped
            contribute(stripped)
            status.capturedCount = flows.count
        }

        /// Drop the oldest overflow past the session display cap (oldest-first
        /// storage → `removeFirst`), counting the drops. Clears the selection if
        /// it was dropped.
        private mutating func enforceDisplayCap() {
            let overflow = flows.count - Self.displayCap
            guard overflow > 0 else { return }
            let dropped = flows.prefix(overflow)
            let droppedIDs = Set(dropped.map(\.id))
            for flow in dropped { retract(flow) }
            flows.removeFirst(overflow)
            droppedFlowCount += overflow
            if let selected = selectedFlowID, droppedIDs.contains(selected) {
                selectedFlowID = nil
            }
            status.capturedCount = flows.count
        }

        /// Whether a flow counts as a failure for the Errors category/badge. One
        /// definition, used by both the count and the list filter.
        static func isError(_ flow: Flow) -> Bool {
            (flow.statusCode ?? 0) >= 400 || flow.error != nil
        }

        /// Fold one flow into the sidebar aggregates.
        private mutating func contribute(_ flow: Flow) {
            if Self.isError(flow) { errorCount += 1 }
            if let host = flow.host { hostCounts[host, default: 0] += 1 }
            if let app = flow.sourceApp {
                appCounts[app.groupingKey, default: 0] += 1
                appReps[app.groupingKey] = app
            }
            if let device = flow.sourceDevice {
                let key = device.groupingKey
                deviceCounts[key, default: 0] += 1
                if var existing = deviceReps[key] {
                    // Keep the richest typing seen across the device's flows.
                    if existing.platform == nil { existing.platform = device.platform }
                    if existing.client == nil { existing.client = device.client }
                    deviceReps[key] = existing
                } else {
                    deviceReps[key] = device
                }
            }
        }

        /// Undo `contribute` — for a replaced or evicted flow. A key that reaches
        /// zero is removed along with its representative, so an emptied host/app/
        /// device disappears from the sidebar instead of lingering at 0.
        private mutating func retract(_ flow: Flow) {
            if Self.isError(flow) { errorCount = max(0, errorCount - 1) }
            if let host = flow.host { _ = Self.decrement(&hostCounts, key: host) }
            if let app = flow.sourceApp, Self.decrement(&appCounts, key: app.groupingKey) {
                appReps[app.groupingKey] = nil
            }
            if let device = flow.sourceDevice, Self.decrement(&deviceCounts, key: device.groupingKey) {
                deviceReps[device.groupingKey] = nil
            }
        }

        /// Decrement a count, removing the key at zero. Returns whether it emptied.
        /// Static so passing one of our own dictionaries `inout` isn't an
        /// overlapping access to `self`.
        private static func decrement(_ counts: inout [String: Int], key: String) -> Bool {
            guard let count = counts[key] else { return false }
            if count <= 1 {
                counts[key] = nil
                return true
            }
            counts[key] = count - 1
            return false
        }

        /// Drop the window's copy of the capture. Used by the Clear button and by
        /// the engine's "cleared" signal (an agent's `clear_flows`), so both paths
        /// leave exactly the same state.
        mutating func forgetCapturedFlows() {
            flows.removeAll()
            hostCounts.removeAll()
            appCounts.removeAll()
            appReps.removeAll()
            deviceCounts.removeAll()
            deviceReps.removeAll()
            errorCount = 0
            selectedFlowID = nil
            selectedFlowDetail = nil
            selectedOriginalDetail = nil
            droppedFlowCount = 0
            status.capturedCount = 0
        }

        /// O(1) emptiness for the selected category, answered from the incremental
        /// aggregates. `requestArea` used to probe `displayFlows.isEmpty`, which
        /// materializes the whole filtered array — a second full O(n) filter per
        /// render, spent entirely on picking the empty state.
        public var displayFlowsAreEmpty: Bool {
            switch selectedCategory ?? .all {
            case .all: return flows.isEmpty
            case .rules, .audit, .breakpoints: return true // the panel replaces the table
            case .errors: return errorCount == 0
            case let .host(host): return hostCounts[host, default: 0] == 0
            case let .app(key): return appCounts[key, default: 0] == 0
            case let .device(ip): return deviceCounts[ip, default: 0] == 0
            }
        }

        /// Requests for the selected category, filtered by search, oldest-first
        /// (chronological — newest at the bottom, like a log/terminal).
        public var displayFlows: [Flow] {
            switch selectedCategory ?? .all {
            case .all:
                // The whole list, handed over without copying (`elements` is the
                // backing array) — this is the common case and runs on every render.
                return flows.elements
            case .rules, .audit, .breakpoints:
                return [] // the rules / audit / breakpoints panel replaces the table
            default:
                break
            }
            var result = flows.elements
            switch selectedCategory ?? .all {
            case .all, .rules, .audit, .breakpoints:
                break
            case .errors:
                result = result.filter(Self.isError)

            case let .host(host):
                // Compared without materializing each flow's host: this runs over the
                // whole list on every render of a host-filtered table.
                result = result.filter { URLHost.hostMatches(urlString: $0.request.url, host: host) }
            case let .app(key):
                result = result.filter { $0.sourceApp?.groupingKey == key }
            case let .device(ip):
                result = result.filter { $0.sourceDevice?.groupingKey == ip }
            }
            return result
        }

        /// Distinct devices with counts — LAN devices first (the phone you just
        /// connected), then by most flows. Reads the incremental aggregates, so this
        /// sorts a handful of devices instead of scanning every flow.
        public var devices: [(device: SourceDevice, count: Int)] {
            deviceCounts.sorted { a, b in
                let da = deviceReps[a.key], db = deviceReps[b.key]
                let la = da?.kind == .lan, lb = db?.kind == .lan
                if la != lb { return la }        // LAN devices float to the top
                return a.value != b.value ? a.value > b.value : a.key < b.key
            }.compactMap { key, count in deviceReps[key].map { (device: $0, count: count) } }
        }

        /// Distinct hosts with counts — pinned first, then alphabetical.
        public var hosts: [(host: String, count: Int)] {
            hostCounts.sorted { a, b in
                let pa = pinnedHosts.contains(a.key), pb = pinnedHosts.contains(b.key)
                if pa != pb { return pa }        // pinned rows float to the top
                return a.key < b.key
            }.map { (host: $0.key, count: $0.value) }
        }

        /// Distinct source apps with counts — pinned first, then most-active.
        /// Keyed by `groupingKey` (bundle id or name); the representative carries the
        /// display name + icon path.
        public var apps: [(app: SourceApp, count: Int)] {
            appCounts
                .sorted { a, b in
                    let pa = pinnedApps.contains(a.key), pb = pinnedApps.contains(b.key)
                    if pa != pb { return pa }    // pinned rows float to the top
                    return a.value != b.value ? a.value > b.value : (a.key < b.key)
                }
                .compactMap { key, count in appReps[key].map { (app: $0, count: count) } }
        }

        public var allCount: Int { flows.count }

        /// Metadata-only selected flow (from the body-free list). The inspector
        /// reads `selectedFlowDetail` for the full payload.
        public var selectedFlow: Flow? { selectedFlowID.flatMap { flows[id: $0] } }
        /// The selected flow with bodies hydrated (fetched on selection / kept
        /// fresh from the live stream). Nil until the fetch lands.
        public var selectedFlowDetail: Flow?
        /// The hydrated `replayedFrom` original of the selection, for the inspector
        /// diff. Nil unless the selection is a replay.
        public var selectedOriginalDetail: Flow?
    }

    public enum Action: BindableAction, Sendable {
        case binding(BindingAction<State>)
        /// The M2 setup child feature (system proxy, SSL, CA trust).
        case setup(SetupFeature.Action)
        /// The traffic-rules child feature (rule CRUD, editor, master switch).
        case rules(RulesFeature.Action)
        /// The breakpoint-supervision child feature (held exchanges, arm/disarm).
        case breakpoints(BreakpointsFeature.Action)
        /// Open the phone-onboarding popover (QR + proxy address). Does not change
        /// LAN connection — that's the popover's own switch.
        case phoneButtonTapped(PhoneOnboardingOrigin)
        /// The phone-onboarding popover child; its `.delegate` reports LAN changes.
        case phone(PresentationAction<PhoneOnboardingFeature.Action>)
        /// Persisted LAN-connection setting loaded at boot.
        case lanEnabledLoaded(Bool)
        /// One-shot boot: start the proxy + subscribe to the flow stream. Sent only
        /// from the always-present menu-bar label so opening a window can't re-run
        /// it (which would cancel the live subscription and restart the proxy).
        case task
        /// Lightweight re-sync when a window/panel appears: reloads config state
        /// without touching the proxy or the flow subscription.
        case viewAppeared
        case localIPResolved(String?)
        case toggleProxyTapped
        case proxyStarted(port: Int)
        case proxyStartFailed(String)
        /// Stamp a rule out of a captured flow and open the editor (parent-owned
        /// because it reads the flow store); forwarded to `RulesFeature`.
        case addRuleFromFlow(Flow.ID, RuleTemplate)
        case flowReceived(Flow)
        /// A coalesced batch of flow updates from the live stream. One action per
        /// window instead of one per emission: an exchange emits 2-3 times (more when
        /// streaming, once per WebSocket frame), and each action drove a full reducer
        /// run plus a SwiftUI invalidation of the table and sidebar.
        case flowsReceived([Flow])
        /// A write action was recorded (seed at boot + live stream).
        case auditEntryReceived(AuditEntry)
        /// The human cleared the audit trail from the panel.
        case auditClearTapped
        case connectedDeviceCountChanged(Int)
        case categorySelected(FlowCategory?)
        case flowSelected(Flow.ID?)
        /// Hydrated bodies for a selection landed (self + optional replay original);
        /// carries the requested id so a stale load for a past selection is ignored.
        case selectedDetailLoaded(id: Flow.ID, flow: Flow?, original: Flow?)
        /// Copy a captured flow as a runnable cURL — fetches the full body first.
        case copyCurlTapped(Flow.ID)
        case replayTapped(Flow.ID)
        case replayFinished(Flow?)
        case clearTapped
        /// The engine's captured set was discarded by someone else — an agent's
        /// `clear_flows` over MCP. Drops the window's copy so the human never
        /// supervises a list of flows the store no longer holds.
        case flowsClearedExternally
        case toggleRecordingTapped
        case pinHostToggled(String)
        case pinAppToggled(String)
        case pinsLoaded(hosts: Set<String>, apps: Set<String>)
        case deviceAliasesLoaded([String: String])
        /// Set (or clear, with nil) a user alias for the device at `ip`.
        case setDeviceAlias(ip: String, alias: String?)
        /// Footer "Check for Updates" / "Update" tap — runs a user-initiated
        /// Sparkle check (shows its download/install UI).
        case checkForUpdatesTapped
        /// A new availability learned from the updater (silent probe or a check).
        case updateAvailabilityChanged(UpdateAvailability)
    }

    @Dependency(\.proxyClient) var proxyClient
    @Dependency(\.updaterClient) var updaterClient
    /// Drives the flow-batching window — a dependency so tests can control it.
    @Dependency(\.continuousClock) var clock

    private enum CancelID { case subscription, updates, audit, devices, cleared }

    public init() {}

    public var body: some ReducerOf<Self> {
        BindingReducer()
        Scope(state: \.setup, action: \.setup) {
            SetupFeature()
        }
        Scope(state: \.rules, action: \.rules) {
            RulesFeature()
        }
        Scope(state: \.breakpoints, action: \.breakpoints) {
            BreakpointsFeature()
        }
        Reduce { state, action in
            switch action {
            case .binding, .setup, .rules, .breakpoints:
                return .none

            case let .phoneButtonTapped(origin):
                // Just open the popover, seeded with the current LAN setting.
                // Dismissing it leaves LAN connection untouched. `origin` records
                // which surface asked, so only that one presents it.
                state.phoneOrigin = origin
                state.phone = PhoneOnboardingFeature.State(lanEnabled: state.lanEnabled)
                return .none

            case let .phone(.presented(.delegate(.lanEnabledChanged(enabled)))):
                // The popover's switch flipped — mirror it into the always-visible
                // icon state and persist. The child already ran/stopped the engine.
                state.lanEnabled = enabled
                return .run { _ in LANCaptureStore.save(enabled) }

            case .phone:
                return .none

            case let .lanEnabledLoaded(enabled):
                state.lanEnabled = enabled
                return .none

            case .task:
                // Idempotent: the menu-bar label can re-render, but boot must run
                // once — re-running would cancel the live flow subscription.
                guard !state.didBoot else { return .none }
                state.didBoot = true
                return .merge(
                    .run { send in
                        let pins = PinsStore.load()
                        await send(.pinsLoaded(hosts: pins.hosts, apps: pins.apps))
                        await send(.deviceAliasesLoaded(DeviceAliasStore.load()))
                        await send(.localIPResolved(LocalIP.primaryIPv4()))
                        do {
                            let port = try await proxyClient.start(9090)
                            await send(.proxyStarted(port: port))
                        } catch {
                            // A bind failure (port in use) must not abort the whole
                            // effect — still load config + subscribe so the UI is live.
                            await send(.proxyStartFailed(error.localizedDescription))
                        }
                        // LAN device connection is allowed by default: make the proxy
                        // LAN-reachable at boot so phones can connect without opening
                        // the popover first. The switch in the popover flips this.
                        let lan = LANCaptureStore.load()
                        await send(.lanEnabledLoaded(lan))
                        if lan { _ = try? await proxyClient.startPhoneOnboarding() }
                        await send(.viewAppeared)
                        // Seed history as one batch, not 200 separate actions.
                        await send(.flowsReceived(await proxyClient.recentFlows(200).reversed()))
                        await Self.streamFlows(
                            into: send,
                            flowStream: { await proxyClient.flowStream() },
                            clock: clock
                        )
                    }
                    .cancellable(id: CancelID.subscription, cancelInFlight: true),
                    // Keep the footer button in sync with Sparkle. `.viewAppeared`
                    // (fired below and on each panel open) drives the daily probe.
                    .run { send in
                        for await availability in await updaterClient.availabilityStream() {
                            await send(.updateAvailabilityChanged(availability))
                        }
                    }
                    .cancellable(id: CancelID.updates, cancelInFlight: true),
                    // Write-action audit trail: seed history, then follow live. A
                    // separate effect from the flow subscription because that loop
                    // never returns (its stream is endless).
                    .run { send in
                        for entry in await proxyClient.recentAuditEntries(State.auditDisplayCap).reversed() {
                            await send(.auditEntryReceived(entry))
                        }
                        for await entry in await proxyClient.auditStream() {
                            await send(.auditEntryReceived(entry))
                        }
                    }
                    .cancellable(id: CancelID.audit, cancelInFlight: true),
                    // Connected-device count: follow the proxy's live connection
                    // signal (seeds current on subscribe), so the panel's "Connect
                    // Device" row reflects phones the moment they connect.
                    .run { send in
                        for await count in await proxyClient.connectedDeviceCountStream() {
                            await send(.connectedDeviceCountChanged(count))
                        }
                    }
                    .cancellable(id: CancelID.devices, cancelInFlight: true),
                    // "The capture was discarded" — fires for the window's own Clear
                    // and for an agent's `clear_flows`. Handling it here is what keeps
                    // the human's view honest when the AI wipes the store.
                    .run { send in
                        for await _ in await proxyClient.flowsClearedStream() {
                            await send(.flowsClearedExternally)
                        }
                    }
                    .cancellable(id: CancelID.cleared, cancelInFlight: true),
                    // Breakpoint supervision: seed armed/held state and follow the
                    // hold stream. Owned by the child so its cancellation and its
                    // held-poll stay in one place.
                    .send(.breakpoints(.task)),
                    // Follow the system proxy for the life of the app: another proxy
                    // app can take it at any moment, and the panel must not keep
                    // claiming Loom holds it.
                    .send(.setup(.task))
                )

            case let .connectedDeviceCountChanged(count):
                state.connectedDeviceCount = count
                return .none

            case .viewAppeared:
                // Cheap re-sync of config state on window/panel open — each child
                // self-loads; never restarts the proxy or the flow subscription.
                return .merge(
                    .send(.setup(.refresh)),
                    .send(.rules(.refreshRules)),
                    .send(.breakpoints(.refresh)),
                    // Silent, self-gated to once a day — cheap to call on every open.
                    .run { _ in await updaterClient.checkInBackgroundIfDue() }
                )

            case let .proxyStartFailed(message):
                state.status.isRunning = false
                state.setup.systemProxyMessage = "Proxy failed to start: \(message)"
                return .none

            case .toggleProxyTapped:
                if state.status.isRunning {
                    state.status.isRunning = false
                    return .run { _ in await proxyClient.stop() }
                }
                return .run { send in
                    let port = try await proxyClient.start(9090)
                    await send(.proxyStarted(port: port))
                }

            case let .localIPResolved(ip):
                state.localIP = ip
                return .none

            case let .addRuleFromFlow(id, template):
                // Fetch the full flow (bodies hydrated) so a "Mock This Response"
                // rule captures the actual response body — the list copy is
                // metadata-only. Nothing is persisted until the editor's Save.
                return .run { send in
                    guard let flow = await proxyClient.flow(id),
                          let rule = RuleFactory.rule(from: flow, template: template)
                    else { return }
                    await send(.rules(.presentEditor(rule: rule, isNew: true)))
                }

            case let .proxyStarted(port):
                state.status.isRunning = true
                state.status.port = port
                return .none

            case let .flowsReceived(flows):
                state.recordFlows(flows)
                // The stream copies still carry bodies; if the open selection is in
                // the batch, keep the inspector's hydrated copy live (same as the
                // single-flow path below). `last(where:)` matches the old per-flow
                // loop, which left the batch's final update in place.
                if let selected = state.selectedFlowID,
                   let update = flows.last(where: { $0.id == selected }) {
                    state.selectedFlowDetail = update
                }
                return .none

            case let .flowReceived(flow):
                state.recordFlow(flow)
                // The stream copy still carries bodies; if it's the open selection,
                // refresh the inspector's hydrated copy directly (no extra fetch),
                // so a completing/streaming flow's body stays live.
                if flow.id == state.selectedFlowID {
                    state.selectedFlowDetail = flow
                }
                return .none

            case let .auditEntryReceived(entry):
                // Stored oldest-first (newest appended at the end), like the flow
                // list — the panel shows a chronological log with the newest at the
                // bottom. Dedup by id (a re-seed after a resubscribe could repeat),
                // then bound to the display cap by dropping the oldest.
                if let existing = state.auditEntries.index(id: entry.id) {
                    state.auditEntries[existing] = entry
                } else {
                    state.auditEntries.append(entry)
                    if state.auditEntries.count > State.auditDisplayCap {
                        state.auditEntries.removeFirst(state.auditEntries.count - State.auditDisplayCap)
                    }
                }
                return .none

            case .auditClearTapped:
                state.auditEntries.removeAll()
                return .run { _ in await proxyClient.clearAudit() }

            case let .categorySelected(category):
                state.selectedCategory = category
                return .none

            case let .flowSelected(id):
                state.selectedFlowID = id
                state.selectedFlowDetail = nil
                state.selectedOriginalDetail = nil
                guard let id else { return .none }
                // Hydrate the selection's bodies (and its replay original, if any)
                // for the inspector; the list itself is body-free now.
                return .run { send in
                    let flow = await proxyClient.flow(id)
                    var original: Flow?
                    if let originalID = flow?.replayedFrom { original = await proxyClient.flow(originalID) }
                    await send(.selectedDetailLoaded(id: id, flow: flow, original: original))
                }

            case let .selectedDetailLoaded(id, flow, original):
                guard id == state.selectedFlowID else { return .none } // selection moved on
                state.selectedFlowDetail = flow
                state.selectedOriginalDetail = original
                return .none

            case let .copyCurlTapped(id):
                return .run { _ in
                    guard let flow = await proxyClient.flow(id) else { return }
                    let command = Curl.command(flow)
                    await MainActor.run {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(command, forType: .string)
                    }
                }

            case let .replayTapped(id):
                state.rules.rulesMessage = nil // shares the rules panel's error line
                return .run { send in
                    do {
                        let flow = try await proxyClient.replay(id, .none)
                        await send(.replayFinished(flow))
                    } catch {
                        await send(.rules(.ruleWriteFailed("Replay failed: \(error.localizedDescription)")))
                    }
                }

            case let .replayFinished(flow):
                guard let flow else { return .none }
                state.recordFlow(flow)
                state.selectedFlowID = flow.id // jump to the replayed result (after any cap trim)
                state.selectedFlowDetail = flow // the replay result still carries bodies
                state.selectedOriginalDetail = nil
                // Fetch the original for the inspector diff.
                guard let originalID = flow.replayedFrom else { return .none }
                return .run { send in
                    let original = await proxyClient.flow(originalID)
                    await send(.selectedDetailLoaded(id: flow.id, flow: flow, original: original))
                }

            case .clearTapped:
                state.forgetCapturedFlows()
                return .run { _ in await proxyClient.clearFlows() }

            case .flowsClearedExternally:
                // Already-empty is the common case (our own Clear cleared state
                // first, then the engine echoed) — the reset is idempotent.
                state.forgetCapturedFlows()
                return .none

            case .toggleRecordingTapped:
                state.isRecording.toggle()
                let recording = state.isRecording
                // Turning recording on also brings the proxy up if it's stopped —
                // there's nothing to capture while the proxy isn't listening.
                let needStart = recording && !state.status.isRunning
                return .run { send in
                    await proxyClient.setRecording(recording)
                    if needStart {
                        let port = try await proxyClient.start(9090)
                        await send(.proxyStarted(port: port))
                    }
                }

            case let .pinHostToggled(host):
                if state.pinnedHosts.contains(host) { state.pinnedHosts.remove(host) }
                else { state.pinnedHosts.insert(host) }
                let (hosts, apps) = (state.pinnedHosts, state.pinnedApps)
                return .run { _ in PinsStore.save(hosts: hosts, apps: apps) }

            case let .pinAppToggled(key):
                if state.pinnedApps.contains(key) { state.pinnedApps.remove(key) }
                else { state.pinnedApps.insert(key) }
                let (hosts, apps) = (state.pinnedHosts, state.pinnedApps)
                return .run { _ in PinsStore.save(hosts: hosts, apps: apps) }

            case let .pinsLoaded(hosts, apps):
                state.pinnedHosts = hosts
                state.pinnedApps = apps
                return .none

            case let .deviceAliasesLoaded(aliases):
                state.deviceAliases = aliases
                return .none

            case let .setDeviceAlias(ip, alias):
                if let alias, !alias.isEmpty { state.deviceAliases[ip] = alias }
                else { state.deviceAliases[ip] = nil }
                let aliases = state.deviceAliases
                return .run { _ in DeviceAliasStore.save(aliases) }

            case .checkForUpdatesTapped:
                return .run { _ in await updaterClient.checkForUpdates() }

            case let .updateAvailabilityChanged(availability):
                state.updateAvailability = availability
                return .none
            }
        }
        .ifLet(\.$phone, action: \.phone) {
            PhoneOnboardingFeature()
        }
    }
}


// MARK: - Flow stream coalescing

/// Buffer between the engine's flow stream and the store. Emissions arrive as fast
/// as traffic flows (2-3 per exchange, one per WebSocket frame); the UI only needs
/// to redraw at a human rate. Collecting into an actor and draining on a fixed
/// window turns a burst of hundreds of actions per second into ~10, each carrying
/// the batch — so the reducer runs (and SwiftUI invalidates the table + sidebar)
/// once per window instead of once per packet.
private actor FlowBatchBuffer {
    private var flows: [Flow] = []
    /// Set once the stream has ended, so the drain loop can stop on its own instead of
    /// being cancelled out from under a pending send (see `streamFlows`).
    private(set) var isFinished = false

    func append(_ flow: Flow) {
        flows.append(flow)
    }

    func finish() {
        isFinished = true
    }

    /// Take everything buffered so far, leaving the buffer empty.
    func drain() -> [Flow] {
        defer { flows.removeAll(keepingCapacity: true) }
        return flows
    }

    /// Hand a drained batch back, ahead of anything that arrived meanwhile so order is
    /// preserved. Used when the task holding it can no longer be trusted to deliver it
    /// (see `streamFlows`).
    func putBack(_ batch: [Flow]) {
        flows.insert(contentsOf: batch, at: 0)
    }
}

extension AppFeature {
    /// How often batched flow updates reach the store. Long enough to collapse a
    /// burst, short enough that the list still feels live.
    static let flowBatchWindow: Duration = .milliseconds(100)

    /// Consume the engine's flow stream, forwarding it to `send` in windowed
    /// batches. Two concurrent tasks rather than a time check inside the read loop:
    /// with only a check-on-arrival, the last few flows of a burst would sit
    /// unsent until the *next* request arrived — a request that looked like it never
    /// happened. The drain task fires on the window regardless of traffic.
    static func streamFlows(
        into send: Send<Action>,
        flowStream: @escaping @Sendable () async -> AsyncStream<Flow>,
        clock: any Clock<Duration>
    ) async {
        let buffer = FlowBatchBuffer()
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                for await flow in await flowStream() {
                    await buffer.append(flow)
                }
                // Tell the drain task there is no more input, rather than cancelling it.
                await buffer.finish()
            }
            group.addTask {
                while await !buffer.isFinished, !Task.isCancelled {
                    try? await clock.sleep(for: Self.flowBatchWindow)
                    // Woken by cancellation rather than by the window elapsing: don't
                    // touch the buffer at all. `Send` silently discards an action when
                    // `Task.isCancelled`, so draining here would empty the buffer into a
                    // batch that is then dropped on the floor — and the parent's flush
                    // below would find nothing left to recover.
                    if Task.isCancelled { return }
                    let batch = await buffer.drain()
                    guard !batch.isEmpty else { continue }
                    // The stream ended while this batch was in hand. `cancelAll()` is
                    // about to land (or already has), so this task can't be trusted to
                    // deliver it: give it back and let the parent — which is never
                    // cancelled by `cancelAll` — send it.
                    if await buffer.isFinished {
                        await buffer.putBack(batch)
                        return
                    }
                    await send(.flowsReceived(batch))
                }
            }
            // The stream ending (engine stopped) ends the drain task too, after one last
            // flush from here so nothing buffered is dropped. This flush runs on the
            // group's parent task, which `cancelAll()` does not cancel — that is what
            // makes it a reliable place to deliver the tail from.
            await group.next()
            group.cancelAll()
            let remainder = await buffer.drain()
            if !remainder.isEmpty { await send(.flowsReceived(remainder)) }
        }
    }
}
