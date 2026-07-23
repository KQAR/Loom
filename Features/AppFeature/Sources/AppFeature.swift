import ComposableArchitecture
import Foundation
import ProxyClient
import SharedModels

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
        public var isRecording = true            // capture gate — the toolbar Record/Stop button
        public var pinnedHosts: Set<String> = [] // sidebar hosts pinned to the top
        public var pinnedApps: Set<String> = []  // sidebar apps pinned to the top (by grouping key)
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
            }
            return result
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
    }

    @Dependency(\.proxyClient) var proxyClient

    private enum CancelID { case subscription }

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

            case .task:
                // Idempotent: the menu-bar label can re-render, but boot must run
                // once — re-running would cancel the live flow subscription.
                guard !state.didBoot else { return .none }
                state.didBoot = true
                return .run { send in
                    let pins = PinsStore.load()
                    await send(.pinsLoaded(hosts: pins.hosts, apps: pins.apps))
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
                .cancellable(id: CancelID.subscription, cancelInFlight: true)

            case .viewAppeared:
                // Cheap re-sync of config state on window/panel open — each child
                // self-loads; never restarts the proxy or the flow subscription.
                return .merge(
                    .send(.setup(.refresh)),
                    .send(.rules(.refreshRules))
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
            }
        }
    }
}
