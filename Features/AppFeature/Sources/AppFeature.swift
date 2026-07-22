import ComposableArchitecture
import Foundation
import PrivilegedHelperClient
import ProxyClient
import SharedModels

/// Left-sidebar categories in the main window. `.host` groups by domain,
/// `.app` by the originating local app (its bundle id or name).
public enum FlowCategory: Hashable, Sendable {
    case all
    case errors
    case replayed
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
        public var filterText: String = ""

        // Config surfaced in the status-bar console / toolbar.
        public var localIP: String?             // this machine's LAN IPv4, for display
        public var isSystemProxy = false        // M2: set via privileged helper
        public var sslEnabled = false           // M2: HTTPS interception (SSL parsing)
        public var certificateStatus = CertificateStatus.notGenerated // M2
        public var sslScope = SSLScope.disabled  // M2: interception scope
        public var certBusy = false              // M2: a trust action is running
        public var certActionMessage: String?    // M2: transient feedback under the cert card
        public var systemProxyBusy = false       // M2: system-proxy change in flight
        public var systemProxyMessage: String?   // M2: transient feedback under the row
        public var rulesEnabled = false         // M3: rule engine
        public var enabledRules: [String] = []   // M3: names of active rules
        public var isIntercepting = false        // M3: breakpoint interception (no UI yet)
        public var isRecording = true            // capture gate — the toolbar Record/Stop button
        public var pinnedHosts: Set<String> = [] // sidebar hosts pinned to the top
        public var pinnedApps: Set<String> = []  // sidebar apps pinned to the top (by grouping key)

        public var displayHost: String { localIP ?? "127.0.0.1" }

        public init() {}

        /// Requests for the selected category, filtered by search, newest-first.
        public var displayFlows: [Flow] {
            var result = Array(flows.reversed())
            switch selectedCategory ?? .all {
            case .all:
                break
            case .errors:
                result = result.filter { ($0.statusCode ?? 0) >= 400 || $0.error != nil }
            case .replayed:
                result = result.filter { $0.replayedFrom != nil }
            case let .host(host):
                result = result.filter { $0.host == host }
            case let .app(key):
                result = result.filter { $0.sourceApp?.groupingKey == key }
            }
            if !filterText.isEmpty {
                let query = filterText.lowercased()
                result = result.filter { flow in
                    flow.request.url.lowercased().contains(query)
                        || flow.request.method.lowercased().contains(query)
                        || (flow.statusCode.map(String.init)?.contains(query) ?? false)
                }
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
        case task
        case localIPResolved(String?)
        case toggleProxyTapped
        case toggleSystemProxyTapped
        case systemProxyResult(enabling: Bool, ok: Bool, message: String?)
        case systemProxyStateLoaded(Bool)
        case toggleSSLTapped
        case toggleRulesTapped
        case proxyStarted(port: Int)
        case certificateStatusLoaded(CertificateStatus)
        case sslScopeLoaded(SSLScope)
        case flowReceived(Flow)
        case categorySelected(FlowCategory?)
        case flowSelected(Flow.ID?)
        case replayTapped(Flow.ID)
        case replayFinished(Flow?)
        case clearTapped
        case toggleInterceptTapped
        case toggleRecordingTapped
        case pinHostToggled(String)
        case pinAppToggled(String)
        case pinsLoaded(hosts: Set<String>, apps: Set<String>)
        case exportCATapped
        case caExported(URL?)
        case installAndTrustCATapped
        case recheckCertTapped
        case certActionStarted(String)
        case certActionFinished(message: String?)
    }

    @Dependency(\.proxyClient) var proxyClient
    @Dependency(\.privilegedHelperClient) var privilegedHelperClient

    private enum CancelID { case subscription }

    public init() {}

    public var body: some ReducerOf<Self> {
        BindingReducer()
        Reduce { state, action in
            switch action {
            case .binding:
                return .none

            case .task:
                return .run { send in
                    let pins = PinsStore.load()
                    await send(.pinsLoaded(hosts: pins.hosts, apps: pins.apps))
                    await send(.localIPResolved(LocalIP.primaryIPv4()))
                    let port = try await proxyClient.start(9090)
                    await send(.proxyStarted(port: port))
                    // Sync with reality: a previous run (or crash) may have left
                    // the system proxy pointing at us.
                    await send(.systemProxyStateLoaded(privilegedHelperClient.isSystemProxyActive(port)))
                    await send(.certificateStatusLoaded(proxyClient.certificateStatus()))
                    await send(.sslScopeLoaded(proxyClient.sslScope()))
                    for flow in await proxyClient.recentFlows(200).reversed() {
                        await send(.flowReceived(flow))
                    }
                    for await flow in await proxyClient.flowStream() {
                        await send(.flowReceived(flow))
                    }
                }
                .cancellable(id: CancelID.subscription, cancelInFlight: true)

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

            case let .systemProxyStateLoaded(active):
                state.isSystemProxy = active
                return .none

            case .toggleSystemProxyTapped:
                guard state.status.isRunning || !state.isSystemProxy else {
                    state.systemProxyMessage = "Start the proxy first."
                    return .none
                }
                let enabling = !state.isSystemProxy
                state.isSystemProxy = enabling // optimistic; reverted if it fails
                state.systemProxyBusy = true
                state.systemProxyMessage = enabling ? "Setting system proxy…" : "Removing system proxy…"
                let port = state.status.port
                // No privileged helper needed: applied via networksetup under one
                // admin prompt (see PrivilegedHelperClient.setSystemProxy).
                return .run { send in
                    let outcome = await privilegedHelperClient.setSystemProxy(enabling, port)
                    await send(.systemProxyResult(enabling: enabling, ok: outcome.ok, message: outcome.message))
                }

            case let .systemProxyResult(enabling, ok, message):
                state.systemProxyBusy = false
                if ok {
                    // Quitting cleans up both the proxy and the QUIC block (see
                    // AppDelegate); a crash leaves them — the boot-time sync surfaces it.
                    state.systemProxyMessage = enabling
                        ? "On — QUIC blocked so browser (HTTP/3) traffic is captured. Restored when Loom quits."
                        : nil
                } else {
                    state.isSystemProxy = !enabling // revert the optimistic toggle
                    state.systemProxyMessage = message ?? "System proxy change failed."
                }
                return .none

            case .toggleSSLTapped:
                let enabling = !state.sslEnabled
                state.sslEnabled = enabling
                var next = state.sslScope
                next.enabled = enabling
                // First time on with no rules: default to intercept-all; the human
                // or agent narrows it. Pinned hosts go in `exclude`.
                if enabling, next.include.isEmpty { next.include = ["*"] }
                state.sslScope = next
                let scope = next
                return .run { send in
                    await proxyClient.setSSLScope(scope)
                    await send(.certificateStatusLoaded(proxyClient.certificateStatus()))
                }

            case .toggleRulesTapped:
                // UI wired now; the map/rewrite (mock) rule engine is M3.
                state.rulesEnabled.toggle()
                return .none

            case let .proxyStarted(port):
                state.status.isRunning = true
                state.status.port = port
                return .none

            case let .certificateStatusLoaded(status):
                state.certificateStatus = status
                return .none

            case let .sslScopeLoaded(scope):
                state.sslScope = scope
                state.sslEnabled = scope.enabled
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
                return .run { send in
                    let flow = try? await proxyClient.replay(id, .none)
                    await send(.replayFinished(flow))
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

            case .toggleInterceptTapped:
                // Placeholder until M3 breakpoint interception; no UI sends this yet.
                state.isIntercepting.toggle()
                return .none

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

            case .exportCATapped:
                return .run { send in
                    let url = try? await proxyClient.exportCACertificate()
                    await send(.caExported(url))
                }

            case let .caExported(url):
                if let url {
                    state.certificateStatus.exportedPEMPath = url.path
                    RevealInFinder.reveal(path: url.path)
                }
                return .none

            case .installAndTrustCATapped:
                // In-app trust for the current user: add the CA to the login keychain
                // and set user-domain trust. No privileged helper or Developer ID
                // needed — macOS prompts once for the login password.
                return .run { send in
                    await send(.certActionStarted("Requesting trust — enter your login password…"))
                    let result = await proxyClient.trustCertificate()
                    await send(.certificateStatusLoaded(proxyClient.certificateStatus()))
                    await send(.certActionFinished(
                        message: result.ok ? "Trusted. HTTPS interception is ready." : (result.message ?? "Trust was not granted.")
                    ))
                }

            case .recheckCertTapped:
                return .run { send in
                    await send(.certActionStarted("Re-checking trust…"))
                    await send(.certificateStatusLoaded(proxyClient.certificateStatus()))
                    await send(.certActionFinished(message: nil))
                }

            case let .certActionStarted(message):
                state.certBusy = true
                state.certActionMessage = message
                return .none

            case let .certActionFinished(message):
                state.certBusy = false
                state.certActionMessage = message
                return .none
            }
        }
    }
}
