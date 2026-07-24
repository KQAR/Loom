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
        /// Most audit entries the window keeps in memory this session (matches the
        /// engine ring + durable-store cap).
        public static let auditDisplayCap = 3000

        // Config surfaced in the status-bar console / toolbar.
        public var localIP: String?             // this machine's LAN IPv4, for display
        /// The M2 setup surface (system proxy, SSL interception, CA trust) — split
        /// into its own feature. It mirrors `status.port`/`isRunning`.
        public var setup = SetupFeature.State()
        /// The traffic-rules surface (rule set, editor, writes) — split into its
        /// own feature. Flow capture/selection/pins stay in the parent.
        public var rules = RulesFeature.State()
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
        public var pinnedHosts: Set<String> = [] // sidebar hosts pinned to the top
        public var pinnedApps: Set<String> = []  // sidebar apps pinned to the top (by grouping key)
        public var deviceAliases: [String: String] = [:] // user labels for devices, keyed by IP
        /// Auto-update state (Sparkle). `.available` flips the footer button to
        /// its prominent "Update" style; a silent daily probe keeps it fresh.
        public var updateAvailability: UpdateAvailability = .unknown
        var didBoot = false                      // guards the one-shot boot effect

        public var displayHost: String { localIP ?? "127.0.0.1" }

        public init() {}

        /// Upsert a flow, then enforce the session display cap by dropping the
        /// oldest overflow (oldest-first storage → `removeFirst`), counting the
        /// drops. An upsert of an existing id doesn't grow the array, so this only
        /// trims on genuinely new flows. Clears the selection if it was dropped.
        mutating func recordFlow(_ flow: Flow) {
            // Store metadata only — bodies for up to 2000 flows would be a large RAM
            // sink; the inspector hydrates the selected flow's body on demand.
            flows[id: flow.id] = flow.strippingBodies()
            let overflow = flows.count - Self.displayCap
            if overflow > 0 {
                let droppedIDs = Set(flows.prefix(overflow).map(\.id))
                flows.removeFirst(overflow)
                droppedFlowCount += overflow
                if let selected = selectedFlowID, droppedIDs.contains(selected) {
                    selectedFlowID = nil
                }
            }
            status.capturedCount = flows.count
        }

        /// Requests for the selected category, filtered by search, oldest-first
        /// (chronological — newest at the bottom, like a log/terminal).
        public var displayFlows: [Flow] {
            var result = Array(flows)
            switch selectedCategory ?? .all {
            case .all:
                break
            case .errors:
                result = result.filter { ($0.statusCode ?? 0) >= 400 || $0.error != nil }
            case .rules, .audit:
                return [] // the rules / audit panel replaces the table

            case let .host(host):
                result = result.filter { $0.host == host }
            case let .app(key):
                result = result.filter { $0.sourceApp?.groupingKey == key }
            case let .device(ip):
                result = result.filter { $0.sourceDevice?.groupingKey == ip }
            }
            return result
        }

        /// Distinct devices with counts — LAN devices first (the phone you just
        /// connected), then by most flows. Mirrors `hosts`/`apps`.
        public var devices: [(device: SourceDevice, count: Int)] {
            var reps: [String: SourceDevice] = [:]
            var counts: [String: Int] = [:]
            for flow in flows {
                guard let device = flow.sourceDevice else { continue }
                let key = device.groupingKey
                counts[key, default: 0] += 1
                if var existing = reps[key] {
                    // Keep the richest typing seen across the device's flows.
                    if existing.platform == nil { existing.platform = device.platform }
                    if existing.client == nil { existing.client = device.client }
                    reps[key] = existing
                } else {
                    reps[key] = device
                }
            }
            return counts.sorted { a, b in
                let da = reps[a.key], db = reps[b.key]
                let la = da?.kind == .lan, lb = db?.kind == .lan
                if la != lb { return la }        // LAN devices float to the top
                return a.value != b.value ? a.value > b.value : a.key < b.key
            }.compactMap { key, count in reps[key].map { (device: $0, count: count) } }
        }

        /// Distinct hosts with counts — pinned first, then alphabetical.
        public var hosts: [(host: String, count: Int)] {
            var counts: [String: Int] = [:]
            for flow in flows {
                if let host = flow.host { counts[host, default: 0] += 1 }
            }
            return counts.sorted { a, b in
                let pa = pinnedHosts.contains(a.key), pb = pinnedHosts.contains(b.key)
                if pa != pb { return pa }        // pinned rows float to the top
                return a.key < b.key
            }.map { (host: $0.key, count: $0.value) }
        }

        /// Distinct source apps with counts — pinned first, then most-active.
        /// Keyed by `groupingKey` (bundle id or name); a representative `SourceApp`
        /// carries the display name + icon path.
        public var apps: [(app: SourceApp, count: Int)] {
            var reps: [String: SourceApp] = [:]
            var counts: [String: Int] = [:]
            for flow in flows {
                guard let app = flow.sourceApp else { continue }
                let key = app.groupingKey
                reps[key] = app
                counts[key, default: 0] += 1
            }
            return counts
                .sorted { a, b in
                    let pa = pinnedApps.contains(a.key), pb = pinnedApps.contains(b.key)
                    if pa != pb { return pa }    // pinned rows float to the top
                    return a.value != b.value ? a.value > b.value : (a.key < b.key)
                }
                .compactMap { key, count in reps[key].map { (app: $0, count: count) } }
        }

        public var allCount: Int { flows.count }
        public var errorCount: Int { flows.filter { ($0.statusCode ?? 0) >= 400 || $0.error != nil }.count }

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

    private enum CancelID { case subscription, updates, audit, devices }

    public init() {}

    public var body: some ReducerOf<Self> {
        BindingReducer()
        Scope(state: \.setup, action: \.setup) {
            SetupFeature()
        }
        Scope(state: \.rules, action: \.rules) {
            RulesFeature()
        }
        Reduce { state, action in
            switch action {
            case .binding, .setup, .rules:
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
                        for flow in await proxyClient.recentFlows(200).reversed() {
                            await send(.flowReceived(flow))
                        }
                        for await flow in await proxyClient.flowStream() {
                            await send(.flowReceived(flow))
                        }
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
                    .cancellable(id: CancelID.devices, cancelInFlight: true)
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
                    // Silent, self-gated to once a day — cheap to call on every open.
                    .run { _ in await updaterClient.checkInBackgroundIfDue() }
                )

            case let .proxyStartFailed(message):
                state.status.isRunning = false
                state.setup.proxyRunning = false
                state.setup.systemProxyMessage = "Proxy failed to start: \(message)"
                return .none

            case .toggleProxyTapped:
                if state.status.isRunning {
                    state.status.isRunning = false
                    state.setup.proxyRunning = false
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
                state.setup.port = port          // mirror into the setup feature
                state.setup.proxyRunning = true
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
                state.flows.removeAll()
                state.selectedFlowID = nil
                state.selectedFlowDetail = nil
                state.selectedOriginalDetail = nil
                state.droppedFlowCount = 0
                state.status.capturedCount = 0
                return .run { _ in await proxyClient.clearFlows() }

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
