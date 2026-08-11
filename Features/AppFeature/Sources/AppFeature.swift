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
        /// Rows the window addresses; older ones are dropped oldest-first.
        ///
        /// The stale half of this comment is worth naming, because it is what the move
        /// to `FlowLimits` is for: it used to say "matches `FlowStore.capacity`", and
        /// that stopped being true the moment this number was raised and the ring's was
        /// not.
        ///
        /// Raised from 2 000 to match what the store actually retains: the durable store
        /// keeps 20 000 exchanges and every one of them is searchable, diffable and
        /// replayable, so a list that stopped at a tenth of them was the surface
        /// disagreeing with the engine again — a host's traffic could be found by the
        /// find bar and counted in the sidebar while having no row.
        ///
        /// What made this affordable is measured, not assumed. The table draws only the
        /// rows in the viewport and applies a batch by diffing rather than reloading, so
        /// an update costs ~46 ms at 20 000 rows against ~42 ms at 2 000 — flat in the
        /// row count (`RequestTable`). The rows themselves are body-free metadata,
        /// measured at ~1.3 KB each: ~26 MB at this cap, against the 61 MB the engine's
        /// body budget already allows itself.
        ///
        /// The **engine's** ring is deliberately not raised with it. Restoring 20 000
        /// rows into it costs 416 ms of decode on the path that binds the listener, for
        /// 13 MB — so history reaches the window through `flowPage` (which reads the
        /// store) after launch instead, and the proxy starts immediately.
        public static let displayCap = FlowLimits.windowRows
        /// How many flows the cap has dropped this session — surfaced in the list
        /// footer so a big capture doesn't *look* like it kept everything.
        public var droppedFlowCount = 0
        /// The two inputs to `displayFlows` that aren't `flows` itself. Both refresh
        /// the cached projection on assignment rather than relying on the caller to —
        /// a cached list whose staleness depends on every mutation site remembering is
        /// a list that renders wrongly and silently. (Mutating a field of `search`
        /// fires this too: a struct property's `didSet` runs on member mutation.)
        public var selectedCategory: FlowCategory? = .all {
            didSet { refreshVisibleFlows() }
        }
        public var selectedFlowID: Flow.ID?
        /// The filter bar above the request table. Composes with `selectedCategory`
        /// as AND rather than replacing it — see `FlowSearch` for why the two are
        /// different questions and why this one leaves the sidebar badges alone.
        /// Guarded rather than unconditional: `search` carries fields no row is
        /// filtered by (`isSearching`, `staleCount`, `outOfWindowMatches`), and one
        /// keystroke writes two of them — so the unconditional version scanned the
        /// window twice to answer once. See `FlowSearch.affectsProjection`.
        public var search = FlowSearch() {
            didSet { if search.affectsProjection(comparedTo: oldValue) { refreshVisibleFlows() } }
        }

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
        /// Sidebar counters — **mirrored from the engine, not maintained here.**
        ///
        /// They used to be folded in as flows arrived in this window, which meant every
        /// badge counted the newest 2000 exchanges while the store retained 20 000: a
        /// host with 300 flows showed 12, and a host whose traffic had all aged out of
        /// the window vanished from the sidebar entirely while its flows sat on disk,
        /// searchable and unlisted. This is the same rule the `isRecording` bug taught:
        /// a fact the engine owns is read from the engine, never kept as a second copy
        /// and hoped over.
        ///
        /// It used to add "and windowing the list makes this unavoidable as well as
        /// wrong — at ~120 resident rows the local counts would be off by two orders of
        /// magnitude". **The window is not paged and holds the whole capture** (see
        /// `displayCap`), so that sentence described a surface that does not exist. The
        /// reason above stands on its own and did not need it.
        ///
        /// One of the three inputs to the sidebar's grouping lists; assigning it
        /// re-sorts them (see `refreshSidebarRows`).
        var aggregates = FlowAggregates() {
            didSet { refreshSidebarRows() }
        }
        /// Whether `aggregates` covers stored history yet, or only what the engine has
        /// restored so far (a brief window after launch). Surfaced rather than smoothed
        /// over: "12" and "12 so far" are different claims.
        public var aggregatesCoverHistory = false
        /// `flow id → host` for the rows this window is holding.
        ///
        /// Stays here, and deliberately did not move to the engine with the counters:
        /// it is the one projection that scales with the number of *flows* rather than
        /// the number of distinct hosts, and a per-row map belongs to whoever holds the
        /// rows. The engine holds every retained flow; this window holds what it draws.
        var hostByRow: [Flow.ID: String] = [:]
        /// Flows that failed or answered 4xx/5xx — the sidebar's Errors badge. A
        /// passthrough so the badge and the tests keep reading one name; everything
        /// that *writes* it goes through `FlowAggregates`.
        public var errorCount: Int { aggregates.errorCount }
        // The other two inputs to the sidebar's grouping lists — a pin only changes the
        // order, but the order is what is cached.
        public var pinnedHosts: Set<String> = [] { // sidebar hosts pinned to the top
            didSet { refreshSidebarRows() }
        }
        public var pinnedApps: Set<String> = [] {  // sidebar apps pinned to the top (by grouping key)
            didSet { refreshSidebarRows() }
        }
        public var deviceAliases: [String: String] = [:] // user labels for devices, keyed by IP
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

        /// The address to *tell someone to point a client at* — which is a question
        /// about the listener, not about this machine's addresses. It used to be
        /// `localIP ?? "127.0.0.1"`, i.e. the LAN IP whenever one could be resolved,
        /// regardless of where the proxy was actually bound. Turning LAN device
        /// connection off rebinds the listener to loopback
        /// (`ProxyEngine.stopPhoneOnboarding`) and left the header, the toolbar chip
        /// and the empty state's `curl -x` hint all advertising `192.168.x.x:9090` —
        /// an address that refuses the connection. A wrong address is worse than a
        /// narrow one: it sends someone debugging their client rather than the switch.
        ///
        /// So the listener decides. Bound to `0.0.0.0` with no LAN IPv4 resolved
        /// (Wi-Fi down, or the resolve hasn't landed yet), the honest answer is
        /// `0.0.0.0` — it is reachable on every interface, we just can't name one.
        public var displayHost: String {
            status.isLANReachable ? (localIP ?? "0.0.0.0") : "127.0.0.1"
        }

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
        ///
        /// **That rule got ten times sharper when the cap did.** At 2 000 the wrong
        /// path was merely wasteful; at 20 000 it is quadratic in a number the app
        /// reaches routinely — filling the window one flow at a time took 88 s in the
        /// test suite, which is what surfaced it. The live path is unaffected (the flow
        /// stream is batched into `recordFlows`), but anything that loops over flows
        /// must use the batch entry point.
        mutating func recordFlow(_ flow: Flow) {
            recordFlows([flow])
        }

        /// Upsert a whole stream batch, enforcing the display cap once.
        ///
        /// **Every mutation happens on a local copy, and the observed properties are
        /// assigned exactly once.** That is not tidiness — it is the difference between
        /// linear and quadratic. `flows` is a stored property of an `@ObservableState`
        /// value, and writing through it costs work proportional to what it holds:
        /// measured at a 20 000-row window, one insert *through the state* is **690 µs**
        /// against **2.6 µs** into a plain `IdentifiedArray`. Per flow. A 50-flow capture
        /// batch would have spent 34 ms of the 100 ms window on observation bookkeeping,
        /// and filling the window one flow at a time took 14 s.
        ///
        /// It was invisible at the old 2 000-row cap and surfaced the moment the cap
        /// moved, which is the useful part of the story: the shape was always wrong and
        /// only the size made it show.
        mutating func recordFlows(_ batch: [Flow]) {
            guard !batch.isEmpty else { return }
            var working = flows
            var hosts = hostByRow
            // Ids this batch inserted, in insertion order — i.e. exactly the tail
            // `flows` grew by. The incremental projection below needs the order, not
            // just the membership: a batch can contain a *new* flow's first emission and
            // an *older* new flow's completion in either sequence, so "append as they
            // are seen" and "append in capture order" are not the same list.
            var insertedIDs: [Flow.ID] = []
            for flow in batch {
                // Store metadata only — bodies for a full window would be a large RAM
                // sink; the inspector hydrates the selected flow's body on demand.
                let stripped = flow.strippingBodies()
                if working[id: flow.id] == nil { insertedIDs.append(flow.id) }
                working[id: flow.id] = stripped
                // Only the per-row host map is maintained here; the counts come from the
                // engine, which is the only place that can see everything retained.
                hosts[flow.id] = stripped.host
            }
            let trimmed = enforceDisplayCap(&working, hosts: &hosts)
            flows = working
            hostByRow = hosts
            status.capturedCount = working.count
            // A trim rewrites the head of the list, so there is nothing incremental left
            // to do; every other batch touches only what it carried.
            if trimmed || !recordVisibleFlows(batch, insertedIDs: insertedIDs) {
                refreshVisibleFlows()
            }
        }

        /// How far *below* the cap a trim cuts, so the next one is a batch away.
        ///
        /// `IdentifiedArray.removeFirst` shifts the whole backing storage and rebuilds
        /// the id index, i.e. it costs the window however few rows it drops — measured
        /// at the 20 000-row cap, a steady-state batch cost **1.79 ms against 0.25 ms
        /// below the cap**, and the difference is entirely this call. Trimming exactly
        /// to the cap pays that on *every* batch, ten times a second, forever, because
        /// the very next batch is over again.
        ///
        /// Cutting deeper makes it once per `trimSlack` flows instead — the same trade
        /// `FlowPersistence.pruneSlack` makes one layer down, and for the same reason.
        ///
        /// It cuts **below** the cap rather than letting the window drift above it,
        /// which is the one direction available here: the window may not exceed
        /// `FlowLimits.windowRows`, because that is pinned at the store's own cap and a
        /// row past it is a row on screen whose flow no read can resolve any more
        /// (`FlowLimits.isOrdered`). So the cost is paid in history — up to `trimSlack`
        /// of the oldest rows leave the list earlier than they had to. They have not
        /// left the *capture*: they are on disk, searchable and openable, and
        /// `droppedFlowCount` says so in the list footer.
        ///
        /// 500, the same figure and the same 2.5 %-of-cap trade `FlowPersistence.pruneSlack`
        /// already takes. Past a few hundred the amortization has nothing left to buy (a
        /// trim every ~17 batches is already 0.09 ms per batch) while the history given up
        /// keeps growing linearly.
        ///
        /// **It costs one stated invariant**, and the cost is real rather than
        /// bookkeeping: recording a set of flows one at a time and recording it as one
        /// batch no longer leave the same number of rows, because they cross the cap at
        /// different moments. What survives — and what `batchRecording_matchesPerFlowRecording_atTheCap`
        /// now pins — is that both are suffixes of the same capture, agreeing on every row
        /// the shorter one holds. Batching still cannot change *which* flows are retained,
        /// only how far back the oldest one goes, and by at most this much.
        static let trimSlack = 500

        /// Drop the oldest overflow past the session display cap (oldest-first
        /// storage → `removeFirst`), counting the drops. Clears the selection if
        /// it was dropped. Returns whether anything was trimmed.
        ///
        /// Takes the working copies `inout` rather than touching `self`'s observed
        /// properties, for the reason `recordFlows` documents.
        @discardableResult
        private mutating func enforceDisplayCap(
            _ working: inout IdentifiedArrayOf<Flow>, hosts: inout [Flow.ID: String]
        ) -> Bool {
            guard working.count > Self.displayCap else { return false }
            // `max(1, …)` so a test-sized cap below the slack still makes progress
            // rather than asking for a negative target.
            let target = max(1, Self.displayCap - Self.trimSlack)
            let overflow = working.count - target
            let droppedIDs = Set(working.prefix(overflow).map(\.id))
            // No aggregate retraction: a flow leaving this window has not left the
            // capture, and the engine's counts are over what is retained, not over what
            // is on screen. Retracting here is what made the badges shrink as the
            // window rolled.
            for id in droppedIDs { hosts[id] = nil }
            working.removeFirst(overflow)
            droppedFlowCount += overflow
            if let selected = selectedFlowID, droppedIDs.contains(selected) {
                selectedFlowID = nil
            }
            return true
        }

        /// Count flows that arrived after an engine-scope answer landed — the ones the
        /// visible result provably does not account for.
        ///
        /// Must run **before** `recordFlows`, because "new" means an id the window has
        /// not seen: an exchange emits several times (pending → completed, per
        /// streaming update, per WebSocket frame) and only the first is a flow the
        /// search didn't consider.
        ///
        /// The URL scope needs none of this — it re-filters every render, so it is
        /// live by construction.
        mutating func noteFlowsArrivedDuringSearch(_ batch: [Flow]) {
            guard search.isActive, search.scope.needsEngine, search.engineMatches != nil else { return }
            search.staleCount += batch.count(where: { flows[id: $0.id] == nil })
        }

        /// Whether a flow counts as a failure for the Errors category/badge. One
        /// definition, used by both the count and the list filter — it lives on
        /// `FlowAggregates` (which needs it to maintain the count) and is re-exported
        /// here because `displayFlows` filters on it too.
        static func isError(_ flow: Flow) -> Bool { FlowAggregates.isError(flow) }

        /// Drop the window's copy of the capture. Used by the Clear button and by
        /// the engine's "cleared" signal (an agent's `clear_flows`), so both paths
        /// leave exactly the same state.
        mutating func forgetCapturedFlows() {
            flows.removeAll()
            hostByRow.removeAll()
            // Cleared locally as well as re-read: the engine's own counts go to zero in
            // the same operation, and waiting for the round trip would leave a sidebar
            // full of hosts with no rows behind them for a frame.
            aggregates.removeAll()
            aggregatesCoverHistory = false
            // The bar stays open with its needle — the human didn't close it — but its
            // engine answer is about flows that no longer exist. Cleared rather than
            // left behind, so an id can't be re-matched by a later flow reusing it.
            search.engineMatches = search.engineMatches.map { _ in [] }
            search.staleCount = 0
            selectedFlowID = nil
            selectedFlowDetail = nil
            selectedOriginalDetail = nil
            droppedFlowCount = 0
            status.capturedCount = 0
            refreshVisibleFlows()
        }

        /// Whether the table has any rows to draw.
        ///
        /// Answered from the cached projection, **not** from the sidebar counters any
        /// more. Those now come from the engine and cover everything retained (20 000
        /// rows), while this window holds 2 000 — so a host whose flows have all rolled
        /// out of the window has a non-zero count and no rows, and the old probe would
        /// have rendered an empty table with headers instead of the empty state.
        public var displayFlowsAreEmpty: Bool { visibleFlows.isEmpty }

        /// Requests for the selected category and needle, oldest-first (chronological —
        /// newest at the bottom, like a log/terminal).
        ///
        /// **Cached, not computed per read.** It is read on every render (and twice,
        /// once for the emptiness probe), and it is O(n) in the window whenever a
        /// category or a needle is involved. The inputs change on a schedule the reducer
        /// controls — a flow batch, a category tap, a keystroke — so it is recomputed
        /// there instead, through the one funnel below.
        public var displayFlows: [Flow] { visibleFlows }

        /// Backing store for `displayFlows`. Private so the funnel is the only writer:
        /// a second place that assigns it is a stale list nobody notices, because a
        /// stale list still renders.
        private var visibleFlows: [Flow] = []

        /// `flow id → index into visibleFlows`, so a batch can update the rows it
        /// carried instead of rebuilding the list.
        ///
        /// Maintained **only while something is actually filtering** — see
        /// `projectionIsCheapToRebuild`. With no category and no needle the projection
        /// *is* the capture (`flows.elements`, a COW reference), so a second 20 000-entry
        /// map would be a megabyte and a hash per flow to accelerate work that costs
        /// nothing.
        private var visiblePositions: [Flow.ID: Int] = [:]

        /// Whether recomputing the whole projection is free.
        ///
        /// True in the two cases that dominate: no filter at all (the projection is the
        /// backing array, handed over without copying) and a panel category (the table is
        /// replaced, so the projection is empty). False exactly when a rebuild is a scan
        /// of the window — which is the case the incremental path exists for.
        private var projectionIsCheapToRebuild: Bool {
            switch selectedCategory ?? .all {
            case .rules, .audit, .breakpoints: true
            case .all: !search.isActive
            case .errors, .host, .app, .device: false
            }
        }

        /// Recompute the projection. Called by every mutation that can change it —
        /// a display-cap trim, a clear, a category change and every search action — and
        /// by `recordFlows` whenever the incremental path declines the batch.
        mutating func refreshVisibleFlows() {
            visibleFlows = computeVisibleFlows()
            visiblePositions = projectionIsCheapToRebuild
                ? [:]
                : Dictionary(
                    uniqueKeysWithValues: visibleFlows.enumerated().map { ($0.element.id, $0.offset) }
                )
        }

        /// Fold one capture batch into the projection without rescanning the window.
        ///
        /// Returns **false when it will not do so correctly**, and the caller falls back
        /// to the full rebuild. That shape is the whole safety argument: this is a second
        /// writer of a cached list, which `refreshVisibleFlows` names as the thing that
        /// renders wrongly and silently, so it is allowed to handle only the cases it can
        /// prove and must hand back the rest rather than approximate them.
        ///
        /// What it is for: with a category or a needle, a rebuild filters the whole window
        /// — measured at 20 000 rows, **7.9 ms per batch for a host category and 8.9 ms
        /// for a needle, against 1.8 ms with no filter**, ten times a second, to re-derive
        /// a list that changed by the thirty rows the batch carried. A category selected
        /// under live capture was costing ~8 % of a core in the reducer.
        ///
        /// Three cases are declined, all of them about **order**, because the projection
        /// follows `flows`' insertion order and appending is only correct at the end:
        ///
        /// - a row already shown that stops matching (it leaves a hole mid-list),
        /// - a row *not* shown that starts matching (`.errors` when a pending exchange
        ///   fails, `.app` when attribution is backfilled — it belongs at its own position
        ///   in the capture, not at the end),
        /// - anything at all when the cap trimmed, handled by the caller.
        ///
        /// The flows this batch *inserted* are the one thing that can be appended, and
        /// they are appended in `insertedIDs` order rather than in the order they were
        /// seen — those differ whenever a slow exchange completes after a faster one
        /// started, which is ordinary traffic, not an edge case.
        /// **Every mutation happens on a local copy and the observed properties are
        /// assigned once**, for the reason `recordFlows` spells out and this method
        /// re-learned the hard way: `visibleFlows` is a stored property of an
        /// `@ObservableState` value, so writing *through* it costs work proportional to
        /// what it holds. The first version appended and subscripted through `self` and
        /// made the needle case **worse than the rebuild it replaced** — 44 ms per batch
        /// against 8.9 ms — because thirty appends through observed state at a 20 000-row
        /// window is thirty times that overhead. Nothing about the algorithm changed to
        /// fix it.
        private mutating func recordVisibleFlows(_ batch: [Flow], insertedIDs: [Flow.ID]) -> Bool {
            guard !projectionIsCheapToRebuild else { return false }
            let matches = search.predicate()
            let inserted = Set(insertedIDs)
            var working = visibleFlows
            var positions = visiblePositions

            // Rows the capture already held: update in place, or decline.
            for flow in batch where !inserted.contains(flow.id) {
                guard let updated = flows[id: flow.id] else { return false }
                let shouldShow = categoryMatches(updated) && matches(updated)
                if let index = positions[flow.id] {
                    guard shouldShow else { return false }
                    working[index] = updated
                } else if shouldShow {
                    return false
                }
            }

            // Rows this batch created: the tail, in capture order. Read back from `flows`
            // rather than from `batch`, so a flow that emitted twice in one batch is
            // appended once and carries its final state.
            for id in insertedIDs {
                guard let flow = flows[id: id] else { continue }
                guard categoryMatches(flow) && matches(flow) else { continue }
                positions[id] = working.count
                working.append(flow)
            }
            visibleFlows = working
            visiblePositions = positions
            return true
        }

        /// Whether the sidebar's selected category admits this flow. One definition,
        /// shared by the full rebuild and the incremental fold — two copies of a
        /// membership rule is two lists that disagree.
        private func categoryMatches(_ flow: Flow) -> Bool {
            switch selectedCategory ?? .all {
            case .all: true
            case .rules, .audit, .breakpoints: false // the panel replaces the table
            case .errors: Self.isError(flow)
            // A dictionary lookup, not a parse: the host was computed once when the flow
            // was recorded, and it is the value the sidebar's categories are keyed by.
            // Scanning the URL string here instead cost 3.2 ms per render over a full ring.
            case let .host(host): hostByRow[flow.id] == host
            case let .app(key): flow.sourceApp?.groupingKey == key
            case let .device(ip): flow.sourceDevice?.groupingKey == ip
            }
        }

        private func computeVisibleFlows() -> [Flow] {
            // Built once for the whole scan, never per row — the needle is trimmed and
            // prepared here (`FlowSearch.predicate`), which is the difference between
            // 84 ms and 0.8 ms over a full window.
            let matches = search.predicate()
            switch selectedCategory ?? .all {
            case .all:
                // The whole list, handed over without copying (`elements` is the
                // backing array) — this is the common case. A needle is the one thing
                // that makes it cost a scan.
                return search.isActive ? flows.elements.filter(matches) : flows.elements
            case .rules, .audit, .breakpoints:
                return [] // the rules / audit / breakpoints panel replaces the table
            default:
                break
            }
            // The needle applies *after* the category, which is also the order the
            // engine query is built in (`FlowSearch.engineQuery`) — so the two paths
            // narrow by the same thing in the same order. One pass rather than two:
            // `categoryMatches` is the same predicate the incremental fold applies, so
            // the two writers of this list cannot disagree about membership.
            let filtering = search.isActive
            return flows.elements.filter { categoryMatches($0) && (!filtering || matches($0)) }
        }

        /// One sidebar grouping row. A named type rather than the tuple these used to
        /// be, for one reason: a tuple cannot be stored in `Equatable` state, and these
        /// are stored now (see `refreshSidebarRows`). Field names are unchanged, so
        /// every reader — `entry.host`, `map(\.app.groupingKey)`, `ForEach(id:
        /// \.device.groupingKey)` — reads exactly as before.
        public struct HostRow: Equatable, Sendable {
            public let host: String
            public let count: Int
        }

        public struct AppRow: Equatable, Sendable {
            public let app: SourceApp
            public let count: Int
        }

        public struct DeviceRow: Equatable, Sendable {
            public let device: SourceDevice
            public let count: Int
        }

        /// Distinct devices with counts — LAN devices first (the phone you just
        /// connected), then by most flows.
        public var devices: [DeviceRow] { sidebarDevices }

        /// Distinct hosts with counts — pinned first, then alphabetical.
        public var hosts: [HostRow] { sidebarHosts }

        /// Distinct source apps with counts — pinned first, then most-active.
        /// Keyed by `groupingKey` (bundle id or name); the representative carries the
        /// display name + icon path.
        public var apps: [AppRow] { sidebarApps }

        private var sidebarHosts: [HostRow] = []
        private var sidebarApps: [AppRow] = []
        private var sidebarDevices: [DeviceRow] = []

        /// Re-sort the three grouping lists.
        ///
        /// **Cached rather than computed on read**, for the reason `displayFlows`
        /// already is: the sidebar body reads all three, and it re-runs on every capture
        /// batch. Each was a dictionary sort plus a `compactMap` — measured over a
        /// 20 000-flow capture across 200 hosts, **0.60 ms for the three of them, per
        /// render**, to produce a list that changes only when a host is first seen, a
        /// count moves, or something is pinned.
        ///
        /// They were never scans of the capture (`FlowAggregates` maintains the counts
        /// incrementally, which is what moved them off the flow list in the first
        /// place), so this is the second half of that same fix rather than a new idea:
        /// the counts stopped being recomputed, and now their *ordering* has too.
        ///
        /// Driven by `didSet` on all three inputs — the aggregates and the two pin sets
        /// — not by call sites remembering, which is the rule `refreshVisibleFlows`
        /// states and the failure mode it names: a stale list still renders.
        mutating func refreshSidebarRows() {
            sidebarHosts = aggregates.hostCounts.sorted { a, b in
                let pa = pinnedHosts.contains(a.key), pb = pinnedHosts.contains(b.key)
                if pa != pb { return pa }        // pinned rows float to the top
                return a.key < b.key
            }.map { HostRow(host: $0.key, count: $0.value) }

            sidebarApps = aggregates.appCounts
                .sorted { a, b in
                    let pa = pinnedApps.contains(a.key), pb = pinnedApps.contains(b.key)
                    if pa != pb { return pa }    // pinned rows float to the top
                    return a.value != b.value ? a.value > b.value : (a.key < b.key)
                }
                .compactMap { key, count in
                    aggregates.appReps[key].map { AppRow(app: $0, count: count) }
                }

            sidebarDevices = aggregates.deviceCounts.sorted { a, b in
                let da = aggregates.deviceReps[a.key], db = aggregates.deviceReps[b.key]
                let la = da?.kind == .lan, lb = db?.kind == .lan
                if la != lb { return la }        // LAN devices float to the top
                return a.value != b.value ? a.value > b.value : a.key < b.key
            }.compactMap { key, count in
                aggregates.deviceReps[key].map { DeviceRow(device: $0, count: count) }
            }
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
        /// Stamp a rule out of a captured flow and open the editor (parent-owned
        /// because it reads the flow store); forwarded to `RulesFeature`.
        case addRuleFromFlow(Flow.ID, RuleTemplate)
        case flowReceived(Flow)
        /// The engine's counts landed (boot, and after each capture burst).
        case flowAggregatesRefreshed(FlowAggregates, coversHistory: Bool)
        /// A coalesced batch of flow updates from the live stream. One action per
        /// window instead of one per emission: an exchange emits 2-3 times (more when
        /// streaming, once per WebSocket frame), and each action drove a full reducer
        /// run plus a SwiftUI invalidation of the table and sidebar.
        case flowsReceived([Flow])
        /// A LAN device connected to (or was first seen by) the proxy.
        case connectedDeviceCountChanged(Int)
        case categorySelected(FlowCategory?)
        case flowSelected(Flow.ID?)

        // MARK: Filter bar (⌘F)
        //
        // The human's half of a capability that was agent-only. `FlowQuery` has
        // carried `urlContains` / `headerContains` / `bodyContains` since M6 and
        // `ProxyClient.recentFlowsMatching` was wired to it — no view ever called it,
        // so an agent could search the capture and the person supervising could not.
        // `ProxyClientParityTests` couldn't catch that: it checks a capability is
        // *wired*, which this was.

        /// ⌘F. Opens the bar (and re-focuses it when already open).
        case searchToggled
        /// Esc, or the bar's ✕. Hides it *and* clears the needle — see `FlowSearch`.
        case searchDismissed
        case searchTextChanged(String)
        case searchScopeChanged(FlowSearchScope)
        /// The bar's "re-run" affordance, for flows captured since the last answer.
        case searchRefreshRequested
        /// An engine-scope answer landed. Carries the needle and scope it was asked
        /// for: the reducer drops it when either has moved on, so a slow body scan
        /// can't overwrite the result of the query typed after it.
        case searchResultsLoaded(ids: Set<Flow.ID>, needle: String, scope: FlowSearchScope)
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
    /// Drives the flow-batching window — a dependency so tests can control it.
    @Dependency(\.continuousClock) var clock

    private enum CancelID {
        case subscription, updates, devices, cleared, localIP, phoneRepublish, mirrorRefresh
        case activation, search, aggregates
    }

    /// How long typing must settle before an engine-scope search is asked.
    ///
    /// Longer than the mirror-refresh window because the work is not comparable: a
    /// `body` needle makes `FlowStore` hydrate every candidate that passed the cheap
    /// predicates, i.e. a disk read per flow. The URL scope is answered locally and
    /// never waits on this.
    static let searchDebounce: Duration = .milliseconds(250)

    /// Re-read the engine's counts, coalesced.
    ///
    /// Every capture batch changes them, so this rides the same trailing-window shape
    /// as the audit fan-out rather than firing per batch: the read is an actor hop plus
    /// a dictionary copy, cheap but not free, and the sidebar does not need to be exact
    /// at 10 Hz. Being *behind* is fine here in a way that being *wrong* was not — the
    /// numbers converge within the window and never drift, because nothing local
    /// maintains them any more.
    private func refreshAggregates() -> Effect<Action> {
        .run { send in
            try await clock.sleep(for: Self.mirrorRefreshDebounce)
            let result = await proxyClient.flowAggregates()
            await send(.flowAggregatesRefreshed(result.aggregates, coversHistory: result.coversHistory))
        }
        .cancellable(id: CancelID.aggregates, cancelInFlight: true)
    }

    /// Ask the engine for the current needle, or tear the query down when the scope
    /// no longer needs one. The single entry point for every input that can change
    /// the answer — needle, scope, and the sidebar category the query is built from.
    private func runSearch(_ state: inout State) -> Effect<Action> {
        guard let query = state.search.engineQuery(category: state.selectedCategory) else {
            // Either the URL scope (answered locally, per keystroke, no hop) or an
            // empty needle. Both mean any parked answer is now noise.
            state.search.engineMatches = nil
            state.search.isSearching = false
            state.search.staleCount = 0
            return .cancel(id: CancelID.search)
        }
        state.search.isSearching = true
        let needle = state.search.needle ?? ""
        let scope = state.search.scope
        let limit = State.displayCap
        return .run { send in
            try await clock.sleep(for: Self.searchDebounce)
            let flows = await proxyClient.recentFlowsMatching(query, limit)
            await send(.searchResultsLoaded(ids: Set(flows.map(\.id)), needle: needle, scope: scope))
        }
        .cancellable(id: CancelID.search, cancelInFlight: true)
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
        Scope(state: \.audit, action: \.audit) {
            AuditFeature()
        }
        Scope(state: \.reverseProxy, action: \.reverseProxy) {
            ReverseProxyFeature()
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

            case .binding, .setup, .rules, .breakpoints, .audit, .reverseProxy:
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
                        let pins = PinsStore.load()
                        await send(.pinsLoaded(hosts: pins.hosts, apps: pins.apps))
                        await send(.deviceAliasesLoaded(DeviceAliasStore.load()))
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
                        // The result is reported now (it used to be discarded): the
                        // address it published for is what the republish watch below
                        // compares against, and boot is where the first one is set.
                        if lan, let info = try? await proxyClient.startPhoneOnboarding() {
                            await send(.phoneOnboardingPublished(info))
                        }
                        await send(.viewAppeared)
                        // Seed from history in one batch, not one action per flow —
                        // and through `flowPage`, which reads the durable store as well
                        // as the ring. `recentFlows(200)` only ever saw memory, so a
                        // relaunch opened on 200 rows with 20 000 exchanges on disk.
                        //
                        // Off the launch path deliberately: restoring the full window
                        // decodes every row it takes (measured at 416 ms for 20 000),
                        // and the proxy must be listening long before then. This runs
                        // after the listener is up, and the rows arrive as one insert.
                        let restored = await proxyClient.flowPage(nil, State.displayCap, .all)
                        await send(.flowsReceived(restored.flows.reversed()))
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
                    guard let info = try? await proxyClient.startPhoneOnboarding() else { return }
                    await send(.phoneOnboardingPublished(info))
                }
                .cancellable(id: CancelID.phoneRepublish, cancelInFlight: true)

            case let .phoneOnboardingPublished(info):
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
                // The other listeners bind inside `start()`, so their ports only
                // exist once it has returned.
                return .run { send in await send(.engineStatusRefreshed(proxyClient.status())) }

            case let .engineStatusRefreshed(status):
                // Merge, don't assign: `capturedCount` counts the *window's* list
                // (bounded, and what the "N flows" row means), and `isRunning` is
                // driven by the toggle here. Everything else is the engine's to know.
                state.status.port = status.port
                state.status.isRecording = status.isRecording
                state.status.listenHost = status.listenHost
                state.status.socksPort = status.socksPort
                state.status.reverseProxies = status.reverseProxies
                state.status.recentRefusals = status.recentRefusals
                state.status.refusedConnections = status.refusedConnections
                return .none

            case let .flowAggregatesRefreshed(aggregates, coversHistory):
                state.aggregates = aggregates
                state.aggregatesCoverHistory = coversHistory
                return .none

            case let .flowsReceived(flows):
                state.noteFlowsArrivedDuringSearch(flows)
                state.recordFlows(flows)
                // The stream copies still carry bodies; if the open selection is in
                // the batch, keep the inspector's hydrated copy live (same as the
                // single-flow path below). `last(where:)` matches the old per-flow
                // loop, which left the batch's final update in place.
                if let selected = state.selectedFlowID,
                   let update = flows.last(where: { $0.id == selected }) {
                    state.selectedFlowDetail = update
                }
                return refreshAggregates()

            case let .flowReceived(flow):
                state.noteFlowsArrivedDuringSearch([flow])
                state.recordFlow(flow)
                // The stream copy still carries bodies; if it's the open selection,
                // refresh the inspector's hydrated copy directly (no extra fetch),
                // so a completing/streaming flow's body stays live.
                if flow.id == state.selectedFlowID {
                    state.selectedFlowDetail = flow
                }
                return refreshAggregates()

            case let .categorySelected(category):
                state.selectedCategory = category
                // The category is part of the engine query (it narrows the scan before
                // any body is hydrated), so switching it invalidates the answer.
                return runSearch(&state)

            case .searchToggled:
                state.search.isPresented = true
                return .none

            case .searchDismissed:
                state.search.dismiss()
                return .cancel(id: CancelID.search)

            case let .searchTextChanged(text):
                state.search.text = text
                return runSearch(&state)

            case let .searchScopeChanged(scope):
                state.search.scope = scope
                return runSearch(&state)

            case .searchRefreshRequested:
                return runSearch(&state)

            case let .searchResultsLoaded(ids, needle, scope):
                // Drop an answer to a question no longer being asked: a body scan
                // hydrates payloads off disk and can easily outlive the keystroke that
                // started it, and landing late would replace the newer result.
                guard state.search.needle == needle, state.search.scope == scope else { return .none }
                state.search.engineMatches = ids
                state.search.isSearching = false
                state.search.staleCount = 0
                // The engine searches memory *and* history; this window holds the
                // newest `FlowLimits.windowRows`. Matches it can't render are counted rather than
                // silently dropped, or the result count would disagree with the rows.
                state.search.outOfWindowMatches = ids.count(where: { state.flows[id: $0] == nil })
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
    /// **Only the parent task ever moves flows out of the buffer.** The child tasks are
    /// cancellable and `Send` *silently discards* an action whose task is cancelled, so a
    /// child that drains and then sends can lose a whole batch to a `cancelAll()` that
    /// lands mid-send — the flows are already out of the buffer, so the parent's final
    /// flush finds nothing to recover and the UI is simply missing requests that were
    /// captured. Guarding around the send is not enough; that was the previous shape, and
    /// it dropped 52 of 200 flows about once in every fifty CI runs
    /// (`FlowStreamBatchingTests.manyEmissions_collapseIntoFewerActions`, runs
    /// 30981021844 and earlier). Cancellation lands *during* an `await`, not only before
    /// it, so no check can close that window.
    ///
    /// So the windowed child now carries **no data at all** — it yields a bare tick and
    /// the parent does every drain and every send. A tick lost to cancellation costs
    /// nothing (the parent drains once more after the loop), ordering is trivially
    /// preserved by there being one consumer, and the buffer holds every flow until the
    /// one task `cancelAll()` cannot touch takes it.
    static func streamFlows(
        into send: Send<Action>,
        flowStream: @escaping @Sendable () async -> AsyncStream<Flow>,
        clock: any Clock<Duration>
    ) async {
        let buffer = FlowBatchBuffer()
        // Ticks, not batches: "the window elapsed" / "the stream ended", never payload.
        let (ticks, tick) = AsyncStream<Void>.makeStream()
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                for await flow in await flowStream() {
                    await buffer.append(flow)
                }
                // The stream ended: one last tick so the parent flushes the tail, then
                // close the tick stream, which is what ends the parent's loop. Ending it
                // from here — rather than cancelling anything — is why the tail can't be
                // stranded.
                await buffer.finish()
                tick.yield(())
                tick.finish()
            }
            group.addTask {
                // Ticks until the stream ends (the parent then cancels this) or the
                // buffer reports finished, whichever comes first. `yield` is
                // non-suspending and unaffected by cancellation, so a tick is never
                // half-delivered.
                while await !buffer.isFinished, !Task.isCancelled {
                    try? await clock.sleep(for: Self.flowBatchWindow)
                    if Task.isCancelled { return }
                    tick.yield(())
                }
            }
            for await _ in ticks {
                let batch = await buffer.drain()
                if !batch.isEmpty { await send(.flowsReceived(batch)) }
            }
            // Stop the windowed child — it may be parked in `clock.sleep` on a clock that
            // is never advanced — and take anything that arrived after the final tick.
            group.cancelAll()
            let remainder = await buffer.drain()
            if !remainder.isEmpty { await send(.flowsReceived(remainder)) }
        }
    }
}
