import ComposableArchitecture
import Foundation
import ProxyClient
import SharedModels
import UpdaterClient

/// Left-sidebar categories in the main window. `.host` groups by domain,
/// `.app` by the originating local app (its bundle id or name).
public enum FlowCategory: Hashable, Sendable {
    case all
    case errors
    case replayed
    /// Not a flow filter: selecting it swaps the detail area for the rules panel.
    case rules
    case host(String)
    case app(String)
    /// Group by originating device (keyed on remote IP): this Mac or a LAN device.
    case device(String)
}

@Reducer
public struct AppFeature: Sendable {
    @ObservableState
    public struct State: Equatable {
        public var status = ProxyStatus(isRunning: false, port: 9090, capturedCount: 0)
        /// Stored oldest-first (insertion order); lists display newest-first.
        public var flows: IdentifiedArrayOf<Flow> = []
        public var selectedCategory: FlowCategory? = .all
        public var selectedFlowID: Flow.ID?

        // Config surfaced in the status-bar console / toolbar.
        public var localIP: String?             // this machine's LAN IPv4, for display
        /// The M2 setup surface (system proxy, SSL interception, CA trust) — split
        /// into its own feature. It mirrors `status.port`/`isRunning`.
        public var setup = SetupFeature.State()
        /// The traffic-rules surface (rule set, editor, writes) — split into its
        /// own feature. Flow capture/selection/pins stay in the parent.
        public var rules = RulesFeature.State()
        /// Phone-onboarding popover (QR + proxy address). Non-nil while shown; the
        /// engine makes the proxy LAN-reachable on present, loopback-only on dismiss.
        @Presents public var phone: PhoneOnboardingFeature.State?
        public var isRecording = true            // capture gate — the toolbar Record/Stop button
        public var pinnedHosts: Set<String> = [] // sidebar hosts pinned to the top
        public var pinnedApps: Set<String> = []  // sidebar apps pinned to the top (by grouping key)
        public var deviceAliases: [String: String] = [:] // user labels for devices, keyed by IP
        /// Auto-update state (Sparkle). `.available` flips the footer button to
        /// its prominent "Update" style; a silent daily probe keeps it fresh.
        public var updateAvailability: UpdateAvailability = .unknown
        var didBoot = false                      // guards the one-shot boot effect

        public var displayHost: String { localIP ?? "127.0.0.1" }

        public init() {}

        /// Requests for the selected category, filtered by search, oldest-first
        /// (chronological — newest at the bottom, like a log/terminal).
        public var displayFlows: [Flow] {
            var result = Array(flows)
            switch selectedCategory ?? .all {
            case .all:
                break
            case .errors:
                result = result.filter { ($0.statusCode ?? 0) >= 400 || $0.error != nil }
            case .replayed:
                result = result.filter { $0.replayedFrom != nil }
            case .rules:
                return [] // the rules panel replaces the table

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
        public var replayedCount: Int { flows.filter { $0.replayedFrom != nil }.count }

        public var selectedFlow: Flow? { selectedFlowID.flatMap { flows[id: $0] } }
    }

    public enum Action: BindableAction, Sendable {
        case binding(BindingAction<State>)
        /// The M2 setup child feature (system proxy, SSL, CA trust).
        case setup(SetupFeature.Action)
        /// The traffic-rules child feature (rule CRUD, editor, master switch).
        case rules(RulesFeature.Action)
        /// Open the phone-onboarding popover (QR + proxy address).
        case phoneButtonTapped
        /// The phone-onboarding popover child; `.dismiss` stops onboarding.
        case phone(PresentationAction<PhoneOnboardingFeature.Action>)
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
        case categorySelected(FlowCategory?)
        case flowSelected(Flow.ID?)
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

    private enum CancelID { case subscription, updates }

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

            case .phoneButtonTapped:
                state.phone = PhoneOnboardingFeature.State()
                return .none

            case .phone(.dismiss):
                // Popover closed — return the proxy to loopback-only.
                return .run { _ in await proxyClient.stopPhoneOnboarding() }

            case .phone:
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
                    .cancellable(id: CancelID.updates, cancelInFlight: true)
                )

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
                guard let flow = state.flows[id: id],
                      let rule = RuleFactory.rule(from: flow, template: template)
                else { return .none }
                // Stamp a rule from the captured flow and hand it to the rules
                // feature to open the editor; nothing is persisted until Save.
                return .send(.rules(.presentEditor(rule: rule, isNew: true)))

            case let .proxyStarted(port):
                state.status.isRunning = true
                state.status.port = port
                state.setup.port = port          // mirror into the setup feature
                state.setup.proxyRunning = true
                return .none

            case let .flowReceived(flow):
                state.flows[id: flow.id] = flow
                state.status.capturedCount = state.flows.count
                return .none

            case let .categorySelected(category):
                state.selectedCategory = category
                return .none

            case let .flowSelected(id):
                state.selectedFlowID = id
                return .none

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
                state.flows[id: flow.id] = flow
                state.selectedFlowID = flow.id // jump to the replayed result
                state.status.capturedCount = state.flows.count
                return .none

            case .clearTapped:
                state.flows.removeAll()
                state.selectedFlowID = nil
                state.status.capturedCount = 0
                return .run { _ in await proxyClient.clearFlows() }

            case .toggleRecordingTapped:
                state.isRecording.toggle()
                let recording = state.isRecording
                return .run { _ in await proxyClient.setRecording(recording) }

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
