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
    case requests
    case connections
    case errors
    /// Not a flow filter: selecting it swaps the detail area for the rules panel.
    case rules
    /// Not a flow filter: swaps the detail area for the write-action audit trail.
    case audit
    /// Not a flow filter: swaps the detail area for held/armed breakpoints — the
    /// one write action that parks a live connection, so it needs a human surface.
    case breakpoints
    case host(String)
    /// Every host at or under one registrable domain — the Hosts tree's parent row
    /// (`HostGrouping` decides membership). Same dimension as `.host`, so a domain
    /// plus one of its own hosts is a union and the domain wins, exactly as a
    /// device plus one of its apps does.
    case domain(String)
    /// One app, **on one device**. The pair, not the app alone: the sidebar nests
    /// apps under the device they ran on, so a row there means "Safari, on the
    /// phone" — and Safari on this Mac is a different row two groups up. Filtering
    /// by the app key alone would make those two rows do the same thing, which is
    /// the one behaviour nesting them is supposed to rule out.
    case app(device: String, key: String)
    /// Group by originating device (keyed on remote IP): this Mac or a LAN device.
    case device(String)

    /// Whether selecting this replaces the request table with a panel rather than
    /// filtering it. The distinction is what lets the sidebar multi-select: filters
    /// compose, panels cannot, and a set holding both is meaningless.
    public var isPanel: Bool {
        switch self {
        case .rules, .audit, .breakpoints: true
        case .all, .requests, .connections, .errors, .host, .domain, .app, .device: false
        }
    }

    /// Whether this narrows the flow list — i.e. everything except the panels and
    /// `.all`, which *is* the unnarrowed list rather than a filter on it.
    public var isFilter: Bool {
        switch self {
        case .all, .rules, .audit, .breakpoints: false
        case .requests, .connections, .errors, .host, .domain, .app, .device: true
        }
    }

    /// Which axis a filter narrows on. Selections **within** one dimension are
    /// OR'd and **across** dimensions are AND'd — two hosts means either host, a
    /// host plus a device means that host's traffic from that device.
    ///
    /// Devices and apps share one dimension on purpose, and it is the one call
    /// here that could reasonably have gone the other way. They are a tree: an app
    /// row is drawn *inside* the device it ran on, so selecting a device and one of
    /// its apps reads as "these two rows", and AND-ing them would silently answer
    /// with the app alone — the smaller of the two things the human clicked. OR
    /// makes the device win, which is what picking a superset should do.
    public enum Dimension: Hashable, Sendable {
        /// Devices and the apps nested under them.
        case origin
        case host
        case recordKind
        /// Not really an axis — a modifier that ANDs with whatever else is picked,
        /// so "errors, on this host" is one selection rather than two steps.
        case errors
    }

    public var dimension: Dimension? {
        switch self {
        case .all, .rules, .audit, .breakpoints: nil
        case .requests, .connections: .recordKind
        case .errors: .errors
        case .host, .domain: .host
        case .app, .device: .origin
        }
    }

    /// Resolve a raw `List` selection into one Loom can act on.
    ///
    /// SwiftUI hands back whatever the click produced; the rules that make a set of
    /// these coherent live here, in one place, rather than in the view. Three of
    /// them, each answering a state the list can genuinely be left in:
    ///
    /// - **A panel is exclusive.** Rules / Audit / Breakpoints replace the table
    ///   rather than filtering it, so they cannot compose with a filter or with
    ///   each other. Whichever side is *newly* added wins, which is what makes
    ///   ⌘-clicking a panel while filters are up do the obvious thing in both
    ///   directions.
    /// - **`.all` is exclusive the same way** — it is the absence of a filter, not
    ///   a filter, so holding it alongside one is a contradiction.
    /// - **An empty selection is `.all`.** Clicking the sidebar's background
    ///   deselects everything, and an empty set would mean "show nothing", which no
    ///   click ever intends.
    public static func normalizeSelection(
        _ selection: Set<FlowCategory>, previous: Set<FlowCategory>
    ) -> Set<FlowCategory> {
        guard !selection.isEmpty else { return [.all] }
        let added = selection.subtracting(previous)
        if let panel = added.first(where: { $0.isPanel || $0 == .all }) { return [panel] }
        let filters = selection.filter(\.isFilter)
        return filters.isEmpty ? [.all] : filters
    }
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

        /// The captured traffic surface — the window's rows, the selection, the find
        /// bar and the sidebar's grouping — split into its own feature.
        ///
        /// Mirrored from nothing and projected from nothing: unlike `setup` and
        /// `reverseProxy`, this child owns its state outright. What the parent still
        /// holds for it is the proxy's lifecycle (`status`), because "is the listener
        /// up" is not a fact about the capture.
        public var capture = CaptureFeature.State()

        /// The write-action audit trail (sidebar → Audit) — split into its own
        /// feature. Nothing here touches captured traffic or the proxy's lifecycle.
        public var audit = AuditFeature.State()

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
                // hands back for them is ignored on the next read. Cleared rather than
                // merely ignored, so two `State` values can't compare unequal over a
                // list neither of them is the source of.
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
        /// The port the proxy is *configured* to listen on, which is not the same
        /// fact as `status.port` — that one is what the engine actually bound, and
        /// the two disagree for exactly as long as a rebind is in flight or has
        /// failed. Persisted (`ProxyPortStore`), so the choice survives relaunch.
        public var configuredPort = ProxyPortStore.defaultPort
        /// Why the listener isn't up, in the operator's words. Its own field rather
        /// than `setup.systemProxyMessage`, which it used to borrow: that channel is
        /// the *system proxy's* feedback line, so a failed start and a failed routing
        /// change overwrote each other and the panel could only ever show one of them.
        /// Cleared the moment a start succeeds.
        public var proxyStartError: String?
        /// Why the proxy is not reachable from the LAN although the switch is on.
        ///
        /// The restore is attempted on **every** path that brings the listener up,
        /// because a start binds loopback — and it was `try?` on both of them, so a
        /// refused rebind (something else holding the port on `0.0.0.0`) left the
        /// phone glyph lit, the switch on, and the phone unable to connect, with
        /// nothing anywhere saying why. Cleared by the next restore that lands.
        public var lanRestoreError: String?
        /// Why the last port change was refused or failed, shown in the address
        /// popover. Cleared when a rebind succeeds.
        public var portError: String?
        /// True while a rebind is in flight — the listener is down for the length of
        /// it, so the popover says so rather than looking idle.
        public var portRebinding = false

        /// The LAN address the phone-onboarding material was last published for.
        ///
        /// The QR *encodes* an address (`http://lanHost:provisioningPort/`) and the
        /// popover prints `lanHost:proxyPort` for the phone's manual proxy fields —
        /// both frozen at publish time. When the machine's address moves, that QR
        /// points at a host that no longer answers, and a phone scanning it gets a
        /// spinner with nothing to say why.
        ///
        /// Kept by the parent, not the popover, because the popover is destroyed
        /// when it closes and the address keeps moving while it's shut.
        var publishedLANHost: String?
        /// The capture gate — the toolbar's Record/Stop button and the colour of
        /// both capture dots.
        ///
        /// A **projection of `status`, not a copy.** This was a separate local flag
        /// defaulting to `true`, and the engine's own answer (`FlowStore.recording`,
        /// carried on `ProxyStatus.isRecording`) was never merged into `status`. So
        /// an agent's `set_recording(false)` stopped capture while the dot stayed
        /// green and the button kept offering "Stop" — and no amount of reopening a
        /// surface fixed it, because nothing read the engine's value anywhere. Green
        /// dot plus no new flows is indistinguishable from a broken proxy.
        ///
        /// `get_proxy_status` reported it correctly to the agent the whole time,
        /// which makes it the log-it-for-the-human/return-it-for-the-agent rule with
        /// the human half missing.
        public var isRecording: Bool {
            get { status.isRecording }
            set { status.isRecording = newValue }
        }
        /// LAN devices connected to the proxy (excludes this Mac). Connection-derived
        /// (fed by `connectedDeviceCountStream`), so a phone counts the moment it
        /// connects — even if its HTTPS is blind-tunneled and never captured.
        public var connectedDeviceCount = 0
        /// Auto-update state (Sparkle). `.available` flips the footer button to
        /// its prominent "Update" style; a silent daily probe keeps it fresh.
        public var updateAvailability: UpdateAvailability = .unknown

        /// The console's Reverse Proxies section — split into its own feature.
        ///
        /// **Projected, not mirrored**, like `setup`: the endpoints live in
        /// `status.reverseProxies` (the one mirror, re-read after every write) and are
        /// filled in on read, so the child can render them without a second list to
        /// keep in step. Whatever it hands back for that field is ignored.
        public var reverseProxy: ReverseProxyFeature.State {
            get {
                var reverseProxy = reverseProxyState
                reverseProxy.endpoints = status.reverseProxies
                return reverseProxy
            }
            set {
                // The projected field is the parent's to own, and it is *cleared* on
                // the way in rather than merely ignored on the next read: leaving a
                // copy in the backing store would make two `State` values compare
                // unequal over a list neither of them is the source of.
                var newValue = newValue
                newValue.endpoints = []
                reverseProxyState = newValue
            }
        }

        /// Backing storage for `reverseProxy` — everything that section genuinely owns.
        var reverseProxyState = ReverseProxyFeature.State()
        var didBoot = false                      // guards the one-shot boot effect

        /// The interface the listener is bound to — **the engine's own answer**
        /// (`status.listenHost`), not a claim assembled here.
        ///
        /// It went through both wrong versions on the way. `localIP ?? "127.0.0.1"`
        /// advertised the LAN IP whenever one could be resolved, so turning LAN
        /// device connection off (which rebinds to loopback) left every surface
        /// naming an address that refuses the connection. Deciding on
        /// `isLANReachable` fixed *that* and kept the second half of the mistake:
        /// with the listener on `0.0.0.0` it printed `10.0.11.196`, which is one
        /// interface of the several it is answering on — a narrower claim than the
        /// truth, and a different fact from the one this line is for.
        ///
        /// Those are two questions. **Where is the listener bound** is what a chip
        /// beside the capture dot answers, and `0.0.0.0` is the honest answer to it.
        /// **What does a phone type in** is the other one, and it belongs to the
        /// material the phone popover publishes (`PhoneOnboardingInfo.lanHost`),
        /// which is resolved by the engine at publish time and carried in the QR —
        /// so answering it here would be a second, independently-derived copy of an
        /// address the two could disagree about.
        public var displayHost: String { status.listenHost }

        public init() {}

        /// Convenience for a state whose capture window already holds `flows` — the
        /// shape tests and previews want. Goes through the child's own initialiser, so
        /// the sidebar aggregates and the cached projection are in sync exactly as they
        /// are for live capture.
        public init(flows: [Flow]) {
            capture = CaptureFeature.State(flows: flows)
        }

    }

    public enum Action: BindableAction, Sendable {
        case binding(BindingAction<State>)
        /// The captured-traffic child feature (rows, selection, find bar, sidebar
        /// grouping, replay, clear).
        case capture(CaptureFeature.Action)
        /// The M2 setup child feature (system proxy, SSL, CA trust).
        case setup(SetupFeature.Action)
        /// The traffic-rules child feature (rule CRUD, editor, master switch).
        case rules(RulesFeature.Action)
        /// The write-action audit trail.
        case audit(AuditFeature.Action)
        /// The console's Reverse Proxies section.
        case reverseProxy(ReverseProxyFeature.Action)
        /// The breakpoint-supervision child feature (held exchanges, arm/disarm).
        case breakpoints(BreakpointsFeature.Action)
        /// Open the phone-onboarding popover (QR + proxy address). Does not change
        /// LAN connection — that's the popover's own switch.
        case phoneButtonTapped(PhoneOnboardingOrigin)
        /// The phone-onboarding popover child; its `.delegate` reports LAN changes.
        case phone(PresentationAction<PhoneOnboardingFeature.Action>)
        /// Persisted LAN-connection setting loaded at boot.
        case lanEnabledLoaded(Bool)
        /// Phone-onboarding material was (re)published — at boot, or by the
        /// republish this feature runs when the machine's LAN address moves.
        case phoneOnboardingPublished(PhoneOnboardingInfo)
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
        /// The engine's own view of the listeners — the ports it actually bound and
        /// the reverse-proxy endpoints. Everything else in `status` is maintained
        /// locally (see the merge in the reducer).
        case engineStatusRefreshed(ProxyStatus)
        case proxyStartFailed(String)
        /// The LAN listener could not be re-opened after a start. LAN stays *on* —
        /// the setting is what the operator asked for and the engine's own rollback
        /// keeps the loopback listener — but nothing on the network can reach it.
        case lanRestoreFailed(String)
        /// The address popover's Apply. Goes through the engine's own port path, so
        /// the human's editor and `set_proxy_port` are one implementation.
        case portSubmitted(Int)
        /// Loaded at boot, because the store is side-effecting.
        case configuredPortLoaded(Int)
        /// The listener is on the new port. Persisted here rather than before the
        /// attempt: a relaunch must not come up on a port the operator asked for and
        /// never got.
        case portRebound(Int)
        /// The port could not be bound. The engine has already put the listener back,
        /// so this carries only what to say.
        case portRebindFailed(requested: Int, message: String)
        /// A LAN device connected to (or was first seen by) the proxy.
        case connectedDeviceCountChanged(Int)
        case toggleRecordingTapped
        /// Footer "Check for Updates" / "Update" tap — runs a user-initiated
        /// Sparkle check (shows its download/install UI).
        case checkForUpdatesTapped
        /// A new availability learned from the updater (silent probe or a check).
        case updateAvailabilityChanged(UpdateAvailability)

        // The reverse-proxy and audit cases that used to sit here moved to
        // `ReverseProxyFeature` and `AuditFeature`; the parent reaches them through
        // `.reverseProxy` / `.audit` above. Their prose stayed behind for two releases,
        // attached to whatever case happened to follow, which is why
        // `ActionDocumentationTests` now fails on a doc comment with no case under it —
        // a stale comment on the wrong declaration is worse than none, because it reads
        // as documentation of the thing it is touching.
    }

    @Dependency(\.proxyClient) var proxyClient
    @Dependency(\.updaterClient) var updaterClient
    /// Drives the trailing windows (the audit fan-out, the phone republish) — a
    /// dependency so tests can control them.
    @Dependency(\.continuousClock) var clock

    private enum CancelID {
        // The flow subscription, the cleared-capture signal, the search query and the
        // aggregate re-read moved to `CaptureFeature` with the state they feed, so
        // their cancellation moved with them.
        case updates, devices, localIP, phoneRepublish, mirrorRefresh, activation
    }

    /// Trailing window for re-reading what an agent wrote. Short enough that the
    /// human never sees a stale surface, long enough that a scripted burst of
    /// writes costs one refresh instead of one per write.
    static let mirrorRefreshDebounce: Duration = .milliseconds(200)

    /// How long the LAN address must hold still before the phone-onboarding
    /// material is republished. A Wi-Fi join settles over several seconds and
    /// several addresses; republishing on each one would tear down and rebind the
    /// provisioning server repeatedly, and the engine refuses a second concurrent
    /// `startPhoneOnboarding` outright (its reentrancy guard throws), so an
    /// un-debounced burst can end with the *last* address never published.
    static let phoneRepublishDebounce: Duration = .seconds(2)

    public init() {}

    public var body: some ReducerOf<Self> {
        BindingReducer()
        Scope(state: \.setup, action: \.setup) {
            SetupFeature()
        }
        // The capture child sorts and marks its host rows by what the scope decrypts,
        // and `SetupFeature` owns the scope. Projected on change rather than filled in
        // on read like `setup.port`: the child caches the sorted rows off a `didSet`,
        // and a computed projection has no `didSet` to drive it.
        //
        // On *this* `Scope`, not on the `Reduce` at the end of the body: a builder
        // modifier wraps only the expression it is written on, so hanging it off the
        // parent's own reducer watched a reducer that never writes the scope — the
        // projection compiled, ran, and never fired (`SidebarScopeProjectionTests`).
        // The scope is written by `SetupFeature` alone, which is what makes this
        // placement complete.
        .onChange(of: \.setup.sslScope) { _, scope in
            Reduce { state, _ in
                state.capture.sslScope = scope
                return .none
            }
        }
        Scope(state: \.audit, action: \.audit) {
            AuditFeature()
        }
        Scope(state: \.reverseProxy, action: \.reverseProxy) {
            ReverseProxyFeature()
        }
        Scope(state: \.capture, action: \.capture) {
            CaptureFeature()
        }
        Scope(state: \.rules, action: \.rules) {
            RulesFeature()
        }
        Scope(state: \.breakpoints, action: \.breakpoints) {
            BreakpointsFeature()
        }
        Reduce { state, action in
            switch action {
            // An agent wrote something a human surface holds a copy of. The audit
            // stream is the one signal every write tool passes through, so this is
            // the whole fan-out: `status` (ports, and the capture gate an agent's
            // `set_recording` moves), the rule set, and the interception config.
            //
            // Deliberately not narrowed per tool. The reads are in-memory snapshots,
            // and an over-broad refresh costs microseconds while a missing one is a
            // surface that quietly disagrees with the engine — which is the state
            // this used to be in for eighteen of the twenty write tools. What *is*
            // filtered out is the tools with their own live stream
            // (`AuditFeature.liveStreamedTools`).
            case .audit(.delegate(.mirroredStateWriteRecorded)):
                // Coalesced rather than filtered per tool. An agent writing fifty
                // rules in a loop must not put fifty `status()` calls behind its
                // work — that call hops onto `FlowStore`, which every capture write
                // queues on — but deciding *which* tools are worth a re-read is the
                // allowlist that rotted in the first place. A trailing window gives
                // the cheap answer without a list to keep in step: one refresh per
                // burst, whatever the burst was made of.
                return .run { send in
                    try await clock.sleep(for: Self.mirrorRefreshDebounce)
                    await send(.engineStatusRefreshed(proxyClient.status()))
                    await send(.rules(.refreshRules))
                    await send(.setup(.refreshAgentWritable))
                }
                .cancellable(id: CancelID.mirrorRefresh, cancelInFlight: true)

            // A reverse-proxy write from the human's own card: only the ports moved.
            case .reverseProxy(.delegate(.needsStatusRefresh)):
                return .run { send in await send(.engineStatusRefreshed(proxyClient.status())) }

            // Everything the capture surface asks the parent for, in **one**
            // exhaustive switch rather than a case per delegate.
            //
            // Not a tidying. A case per delegate sits in front of the catch-all
            // below, which matches bare `.capture` — so a delegate nobody wrote a
            // case for compiles, runs, and is silently dropped. `ignoreHost` was
            // exactly that: an action, a delegate, and a doc comment saying "the
            // parent routes it to the engine", with no case here, no sender in any
            // view and no test. It is deleted rather than wired, because "stop
            // capturing this host" already exists as `RuleActions.dropFromCapture`
            // and a second write path to the same outcome is the thing this
            // codebase does not do.
            //
            // Nested like this, the compiler requires a case per delegate, so the
            // next one cannot arrive unhandled.
            case let .capture(.delegate(delegate)):
                switch delegate {
                // The message line lives on the rules panel (rule writes report
                // there too), so the routing is here rather than in either child:
                // whoever writes it last wins, and only the parent sees both writers.
                case let .stampedRule(rule):
                    return .send(.rules(.presentEditor(rule: rule, isNew: true)))

                case let .replayFailed(message):
                    return .send(.rules(.ruleWriteFailed(message)))

                // Both directions of the scope, picked off a row in the request
                // table. Routed through `SetupFeature` rather than written here, so
                // the table and the console card cannot disagree about what either
                // one does.
                case let .excludeHost(host):
                    return .send(.setup(.excludeHostTapped(host)))

                case let .decryptHost(host):
                    return .send(.setup(.interceptHostTapped(host)))
                }

            // Starting a replay clears the shared line, for the same reason.
            case .capture(.replayTapped):
                state.rules.rulesMessage = nil
                return .none

            case .binding, .setup, .rules, .breakpoints, .audit, .reverseProxy, .capture:
                return .none

            case let .phoneButtonTapped(origin):
                // Just open the popover, seeded with the current LAN setting.
                // Dismissing it leaves LAN connection untouched. `origin` records
                // which surface asked, so only that one presents it.
                state.phoneOrigin = origin
                state.phone = PhoneOnboardingFeature.State(lanEnabled: state.lanEnabled)
                return .none

            case let .phone(.presented(.delegate(.published(info)))):
                // The popover published (its own `.task`, or its switch turning LAN
                // on). Recording the address here is what lets the republish below
                // tell "the machine moved" from "we already published for this".
                state.publishedLANHost = info.lanHost
                return .none

            case let .phone(.presented(.delegate(.lanEnabledChanged(enabled)))):
                // The popover's switch flipped — mirror it into the always-visible
                // icon state and persist. The child already ran/stopped the engine.
                state.lanEnabled = enabled
                // Off means the material is gone and the listener is back on
                // loopback. Forgetting the address it was published for matters:
                // holding on to it would make the next address change look like a
                // republish that had already happened.
                if !enabled {
                    state.publishedLANHost = nil
                }
                return .run { send in
                    LANCaptureStore.save(enabled)
                    // The switch *moved the listener* (`startPhoneOnboarding` /
                    // `stopPhoneOnboarding` rebind between `0.0.0.0` and loopback),
                    // and `listenHost` is what `displayHost` now reads. Only
                    // `.viewAppeared` re-read it, so the main window's toolbar kept
                    // naming the old interface until the panel was next opened.
                    await send(.engineStatusRefreshed(proxyClient.status()))
                }

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
                        // Read before the start, not after: this *is* the port the
                        // listeners come up on, and sending it as a separate action
                        // would race the bind.
                        // Both reads land **before** the start: the port is what the
                        // listeners come up on, and `lanEnabled` is what `proxyStarted`
                        // consults to decide whether to re-open the listener to the LAN
                        // — reading it afterwards would have that decision made against
                        // the default rather than the stored choice.
                        //
                        // LAN device connection is allowed by default, so a phone can
                        // connect without anyone opening the popover first.
                        let configured = ProxyPortStore.load()
                        await send(.configuredPortLoaded(configured))
                        await send(.lanEnabledLoaded(LANCaptureStore.load()))
                        do {
                            let port = try await proxyClient.start(configured)
                            await send(.proxyStarted(port: port))
                        } catch {
                            // A bind failure (port in use) must not abort the whole
                            // effect — still load config + subscribe so the UI is live.
                            await send(.proxyStartFailed(error.localizedDescription))
                        }
                        await send(.viewAppeared)
                        // The capture surface subscribes itself from here rather than at
                        // the top of the merge, and the ordering is the reason: seeding
                        // the window reads history off disk (416 ms for 20 000 rows) and
                        // the listener must be up long before that. So it is sequenced
                        // *after* the start attempt inside this one effect, exactly where
                        // the seed used to sit.
                        await send(.capture(.task))
                    },
                    // Keep the footer button in sync with Sparkle. `.viewAppeared`
                    // (fired below and on each panel open) drives the daily probe.
                    .run { send in
                        for await availability in await updaterClient.availabilityStream() {
                            await send(.updateAvailabilityChanged(availability))
                        }
                    }
                    .cancellable(id: CancelID.updates, cancelInFlight: true),
                    // This machine's LAN IPv4 for the life of the app (seeds current
                    // on subscribe). Resolved once at boot before this, which made
                    // every displayed address a claim about the network Loom launched
                    // on — a Wi-Fi switch or a DHCP renewal left the header naming an
                    // address nothing answers on.
                    .run { send in
                        for await ip in LocalIP.addresses() {
                            await send(.localIPResolved(ip))
                        }
                    }
                    .cancellable(id: CancelID.localIP, cancelInFlight: true),
                    // Re-sync when Loom comes back to the front. The audit-stream
                    // refresh covers the writer that is an agent; this covers the
                    // one that is a human in another app — running the printed
                    // `sudo security add-trusted-cert`, revoking it in Keychain
                    // Access, approving the helper in System Settings. None of those
                    // is a write tool, and the main window's own `.task` fires once
                    // per launch, so nothing re-read them while it stayed open.
                    .run { send in
                        for await _ in AppActivation.events() {
                            await send(.viewAppeared)
                        }
                    }
                    .cancellable(id: CancelID.activation, cancelInFlight: true),
                    // Write-action audit trail: seed history, then follow live. Owned
                    // by the child, so its cancellation lives with the state it feeds.
                    .send(.audit(.task)),
                    // Connected-device count: follow the proxy's live connection
                    // signal (seeds current on subscribe), so the panel's "Connect
                    // Device" row reflects phones the moment they connect.
                    .run { send in
                        for await count in await proxyClient.connectedDeviceCountStream() {
                            await send(.connectedDeviceCountChanged(count))
                        }
                    }
                    .cancellable(id: CancelID.devices, cancelInFlight: true),
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
                    // The listener facts only the engine knows: which ports it bound
                    // (SOCKS fails open, so its number isn't derivable from the HTTP
                    // one) and the reverse-proxy endpoints. Nothing read them before,
                    // which is why the console's SOCKS line — drawn in DESIGN.md —
                    // could never render.
                    .run { send in await send(.engineStatusRefreshed(proxyClient.status())) },
                    // Silent, self-gated to once a day — cheap to call on every open.
                    .run { _ in await updaterClient.checkInBackgroundIfDue() }
                )

            case let .proxyStartFailed(message):
                state.status.isRunning = false
                state.isRecording = false
                state.proxyStartError = message
                return .none

            case .toggleProxyTapped:
                if state.status.isRunning {
                    state.status.isRunning = false
                    return .run { _ in await proxyClient.stop() }
                }
                state.proxyStartError = nil
                let configured = state.configuredPort
                // `try` alone here threw into the effect, where TCA logs it and the
                // action is simply never sent: the switch sprang back with nothing
                // said, on the one failure the operator can fix (the port is taken).
                return .run { send in
                    do {
                        let port = try await proxyClient.start(configured)
                        await send(.proxyStarted(port: port))
                    } catch {
                        await send(.proxyStartFailed(error.localizedDescription))
                    }
                }

            case let .localIPResolved(ip):
                state.localIP = ip
                // The header now follows the address (it reads `localIP` through
                // `displayHost`), but the phone-onboarding material does not: the QR
                // encodes `http://lanHost:provisioningPort/` and the popover prints
                // `lanHost:proxyPort`, both frozen when they were published. After
                // the machine moves networks that QR points at a host that no longer
                // answers, and a phone scanning it just hangs.
                //
                // `startPhoneOnboarding` is idempotent and republishes (its own docs
                // name the LAN IP changing as the case), so the repair is to run it
                // again — but only when there is a *usable* address that is not the
                // one already published. Going offline (`ip == nil`) republishes
                // nothing, because there is nothing to publish: the engine would
                // refuse for want of a LAN address, and the material Loom is holding
                // is the last one that ever worked.
                guard state.lanEnabled, let ip, ip != state.publishedLANHost else { return .none }
                return .run { send in
                    try await clock.sleep(for: Self.phoneRepublishDebounce)
                    do {
                        await send(.phoneOnboardingPublished(try await proxyClient.startPhoneOnboarding()))
                    } catch {
                        // The address moved and the republish for the new one failed:
                        // the QR in anyone's hand now points at an address that has
                        // gone away, which is the case this whole watch exists for.
                        await send(.lanRestoreFailed(error.localizedDescription))
                    }
                }
                .cancellable(id: CancelID.phoneRepublish, cancelInFlight: true)

            case let .lanRestoreFailed(message):
                // The switch is *not* flipped off: LAN is still what the operator
                // asked for, and the engine's rebind rolled back rather than leaving
                // the listener down. What is wrong is narrower than the setting —
                // this machine is not reachable from the network right now — and the
                // console says exactly that instead of quietly disagreeing with
                // itself.
                state.lanRestoreError = message
                return .none

            case let .phoneOnboardingPublished(info):
                state.lanRestoreError = nil
                state.publishedLANHost = info.lanHost
                // An open popover is showing the material this call just replaced —
                // including a QR for an address that has moved. Written straight into
                // the child rather than sent as a child action: the popover is
                // usually *not* open when this lands (the address moves whether or
                // not anyone is looking), and a `.presented` action into a nil
                // presentation is the case TCA warns about, not a no-op.
                state.phone?.info = info
                state.phone?.isLoading = false
                return .none

            case let .configuredPortLoaded(port):
                state.configuredPort = port
                return .none

            case let .portSubmitted(port):
                // Validated here as well as in the card, and *again* in the engine:
                // the card owns the message shown while typing, this owns what may be
                // asked for, and the engine owns what may reach a socket. A reducer
                // that trusts its view is one refactor away from binding whatever was
                // in the field.
                if let refusal = ListenPortRules.refusal(
                    for: port,
                    reserved: [ListenPortRules.mcpControlPort: "Loom's MCP control port"],
                    inUseByLoom: Set(state.status.reverseProxies.compactMap(\.boundPort))
                ) {
                    state.portError = refusal
                    return .none
                }
                guard port != state.status.port else {
                    state.portError = nil
                    return .none
                }
                state.portError = nil
                state.portRebinding = true
                // **Through the engine's own port path**, not a stop-then-start from
                // here. That is what keeps the interface (a `start()` binds loopback,
                // which is how a port change used to close the proxy to the LAN), the
                // roll-back, the SOCKS neighbour and the phone material's republish in
                // one implementation shared with `set_proxy_port`.
                return .run { send in
                    do {
                        await send(.engineStatusRefreshed(try await proxyClient.setListenPort(port)))
                        await send(.portRebound(port))
                    } catch {
                        await send(.portRebindFailed(requested: port, message: error.localizedDescription))
                    }
                }

            case .portRebound:
                // The persisting is `engineStatusRefreshed`'s, which every writer's
                // change passes through. This owns only what the card is showing.
                state.portRebinding = false
                state.portError = nil
                return .none

            case let .portRebindFailed(requested, message):
                state.portRebinding = false
                // The engine put the listener back before throwing, so there is
                // nothing to restart here — only something to say.
                state.portError = "Port \(requested) is unavailable — \(message)"
                return .run { send in await send(.engineStatusRefreshed(proxyClient.status())) }

            case let .proxyStarted(port):
                state.status.isRunning = true
                state.proxyStartError = nil
                state.portRebinding = false
                state.portError = nil
                state.configuredPort = port
                state.status.port = port
                // The other listeners bind inside `start()`, so their ports only
                // exist once it has returned.
                //
                // The system proxy is re-applied when it was pointing at Loom: it
                // holds a *port*, so after a rebind it addresses a listener that is
                // no longer there — every app on the machine loses the network with
                // Loom's switch still reading "on". Not a no-op when the port didn't
                // change, but a silent one (the same value written again), which is
                // cheaper than a second way to be wrong about whether it did.
                //
                // **A start binds loopback.** `ProxyClient.start` passes no host, so
                // the engine takes its `127.0.0.1` default — every path that brings
                // the listener up (boot, the toggle, arming Record, a port change)
                // therefore closes it to the LAN, and a phone that was capturing
                // stops reaching it with nothing on any surface saying why. The port
                // change is where this was found: 9099 applied, the window showed
                // 9099, and the phone's requests went nowhere.
                // `startPhoneOnboarding` is the rebind (0.0.0.0) *and* the republish
                // of the material, which now carries the new port — it is idempotent,
                // which is what lets one call cover all four paths.
                let restoreLAN = state.lanEnabled
                let followSystemProxy = state.setup.isSystemProxy
                return .run { send in
                    if restoreLAN {
                        do {
                            await send(.phoneOnboardingPublished(try await proxyClient.startPhoneOnboarding()))
                        } catch {
                            await send(.lanRestoreFailed(error.localizedDescription))
                        }
                    }
                    // After the LAN rebind, so `listenHost` is the one now bound.
                    await send(.engineStatusRefreshed(proxyClient.status()))
                    if followSystemProxy { await send(.setup(.reapplySystemProxy)) }
                }

            case let .engineStatusRefreshed(status):
                // Merge, don't assign: `isRunning` is driven by the toggle here.
                // Everything else is the engine's to know — **including
                // `capturedCount`**, which it did not used to be. This field was
                // overwritten locally with the *window's* row count, so one name meant
                // the engine's ring in `get_proxy_status` and the window's list here,
                // and the two differ by an order of magnitude at the caps they hold.
                // Nothing on any surface read it (the sidebar's "All Flows" row counts
                // `capture.allCount`, which is what it means), so the local write was a
                // mirror of an engine value quietly disagreeing with the engine — the
                // shape the `isRecording` bug was.
                state.status.capturedCount = status.capturedCount
                state.status.port = status.port
                state.status.isRecording = status.isRecording
                state.status.listenHost = status.listenHost
                state.status.socksPort = status.socksPort
                state.status.reverseProxies = status.reverseProxies
                state.status.recentRefusals = status.recentRefusals
                state.status.refusedConnections = status.refusedConnections
                state.status.socksError = status.socksError
                state.status.listenerError = status.listenerError
                state.status.degradations = status.degradations
                // **Persisting hangs off the read, not off the writer.** The port has
                // two writers — the address editor and `set_proxy_port` — and only the
                // first one used to save it, so a port an agent moved came back as the
                // old one after a relaunch while everything in the session agreed it
                // had changed. Whoever moved it, the engine's answer is the one that
                // gets remembered.
                guard status.isRunning, status.port != state.configuredPort else { return .none }
                state.configuredPort = status.port
                return .run { _ in ProxyPortStore.save(status.port) }


            case .toggleRecordingTapped:
                state.isRecording.toggle()
                let recording = state.isRecording
                // Turning recording on also brings the proxy up if it's stopped —
                // there's nothing to capture while the proxy isn't listening.
                let needStart = recording && !state.status.isRunning
                let configured = state.configuredPort
                return .run { send in
                    await proxyClient.setRecording(recording)
                    guard needStart else { return }
                    do {
                        let port = try await proxyClient.start(configured)
                        await send(.proxyStarted(port: port))
                    } catch {
                        await send(.proxyStartFailed(error.localizedDescription))
                    }
                }


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


