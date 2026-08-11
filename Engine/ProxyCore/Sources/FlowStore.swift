import Foundation
import LoomSharedModels

/// In-memory, bounded store of flows plus a fan-out of live updates.
/// Actor-isolated so the NIO handlers and the UI/MCP readers stay race-free.
actor FlowStore {
    private var flows: [Flow] = []
    /// `id -> absolute position`, so an upsert is a dictionary lookup instead of a
    /// linear scan. An exchange upserts at least twice (pending → completed), a
    /// streaming one more, a WebSocket once per frame — at ring capacity that was a
    /// 2000-element scan every time, on the actor everything else queues behind.
    ///
    /// Positions are *absolute* (`droppedFromFront + arrayIndex`) so evicting from
    /// the front doesn't invalidate the surviving entries: only the evicted ids are
    /// removed and the offset moves. Keeping array indices instead would mean
    /// rewriting every entry on each eviction — trading one linear cost for another.
    private var positions: [UUID: Int] = [:]
    /// How many flows have been evicted from the front of the ring, ever.
    private var droppedFromFront = 0
    private let capacity: Int
    private var continuations: [UUID: AsyncStream<Flow>.Continuation] = [:]
    private var recording = true
    /// Durable backing (nil in tests). Only completed flows are written.
    private let persistence: FlowPersistence?
    private var didLoadPersisted = false

    /// Distinct remote LAN client IPs that have opened a connection to the proxy
    /// this session — i.e. *devices connected to the proxy*, independent of whether
    /// their traffic was ever captured (a blind-tunneled HTTPS phone still counts,
    /// which the flow-derived `SourceDevice` view would miss). Loopback (this Mac)
    /// is excluded. Session-scoped: reset on `clear()` and by a relaunch.
    private var connectedLANIPs: Set<String> = []
    private var deviceCountContinuations: [UUID: AsyncStream<Int>.Continuation] = [:]
    /// Subscribers to "the capture was discarded" — see `clearedStream()`.
    private var clearedContinuations: [UUID: AsyncStream<Void>.Continuation] = [:]

    /// Layer 2: total in-memory body bytes across the ring, and the ceiling. Over
    /// the ceiling, the oldest *persisted* flows' bodies are dropped from memory
    /// (they're safe on disk, re-attached on demand by `hydrated`). The ring keeps
    /// up to `capacity` flows regardless; this bounds their *bytes*, which is what
    /// large bodies actually blow up. Only completed flows are slimmed — an
    /// in-flight body isn't on disk yet — and only when a store backs us.
    private var bodyBytes = 0
    private let bodyBudget: Int
    /// How many leading flows are known permanently body-free (completed and
    /// slimmed/empty), so `enforceBodyBudget` starts scanning where bytes can
    /// actually be reclaimed. Without it, every upsert past the budget — the
    /// steady state of a long capture with large bodies — re-walked the whole
    /// ring from the front just to re-skip flows slimmed long ago. Rebased on
    /// eviction, reset on `clear()`, and pulled back if an upsert re-attaches
    /// bodies behind it.
    private var slimCursor = 0
    /// Push sink for embedders that own storage — fired alongside the stream on
    /// every insert/update. See `FlowObserving`.
    private let observer: FlowObserving?

    /// Per-host / per-app / per-device counts over everything **retained** — the ring
    /// and the durable store together — not over what happens to be in memory.
    ///
    /// Three rules keep it exact, and each is a case where the obvious version drifts:
    ///
    /// - **A flow leaving the ring is not a flow leaving the capture.** Eviction at
    ///   `capacity` moves a completed flow to disk-only; it is still retained and must
    ///   still be counted. An *in-flight* flow evicted before it completed was never
    ///   persisted, so that one is a real removal.
    /// - **An upsert re-counts.** A flow is counted at `.pending` and again at every
    ///   state change, and its error-ness changes underneath: pending isn't an error,
    ///   the 500 it becomes is. Retract-then-contribute on replacement.
    /// - **The pruner removes rows nobody upserted.** `FlowPersistence` drops the
    ///   oldest rows past its cap on its own schedule, and those flows never come back
    ///   through here — so the prune reports what it deleted and the counts retract.
    private var aggregates = FlowAggregates()
    /// Whether the boot aggregation has run. Counts are only claimed to cover history
    /// once it has; before that they cover the ring, which is what they were seeded
    /// with. Reported so a surface can tell "no traffic" from "not counted yet".
    private var aggregatesCoverHistory = false

    init(capacity: Int = FlowLimits.memoryRing, bodyBudget: Int = 64_000_000, persistence: FlowPersistence? = nil, observer: FlowObserving? = nil) {
        self.capacity = capacity
        self.bodyBudget = bodyBudget
        self.persistence = persistence
        self.observer = observer
        // The pruner deletes retained rows on its own schedule with nobody asking, so
        // it has to tell us or the counts drift upward forever.
        persistence?.onPrune = { [weak self] pruned in
            Task { await self?.forgetPruned(pruned) }
        }
    }

    /// Fan a flow out to every live `flowStream()` consumer and the push
    /// observer. The single broadcast point so the stream and the sink can never
    /// diverge.
    ///
    /// Each stream buffers a bounded number of emissions (see `streamBuffer`) and
    /// drops the oldest when a consumer falls behind. A drop is **never silent**:
    /// it means that subscriber's view of the traffic has a hole, which for a
    /// debugging proxy is exactly the kind of thing that must be visible rather
    /// than guessed at.
    private func broadcast(_ flow: Flow) {
        for (id, continuation) in continuations {
            if case .dropped = continuation.yield(flow) {
                noteDrop(subscriber: id)
            }
        }
        observer?.flowDidUpdate(flow)
    }

    /// Per-subscriber dropped-emission counts, so a slow consumer is reported once
    /// per burst rather than once per dropped flow (a stalled UI would otherwise
    /// turn one problem into thousands of log lines).
    private var droppedEmissions: [UUID: Int] = [:]

    private func noteDrop(subscriber: UUID) {
        let count = (droppedEmissions[subscriber] ?? 0) + 1
        droppedEmissions[subscriber] = count
        // 1, 10, 100, 1000 … — enough to see it start and to see it get worse.
        if count == 1 || count % 100 == 0 {
            Log.store.error(
                """
                Flow stream subscriber is behind: \(count, privacy: .public) emission(s) dropped \
                (buffer \(Self.streamBuffer, privacy: .public)). That subscriber's view of \
                captured traffic has gaps — flows are still in the store, but live updates were lost.
                """
            )
        }
    }

    /// How many emissions a `flowStream()` subscriber may fall behind before the
    /// oldest are dropped. Unbounded (the `AsyncStream` default) would let a stalled
    /// consumer grow the buffer without limit while the whole point of the ring and
    /// the body budget is that nothing in memory is unbounded. Sized well above a
    /// UI coalescing window (~100 ms) so normal back-pressure never drops.
    static let streamBuffer = 512

    /// Array index for `id`, or nil when it isn't in the ring. Tolerates a stale
    /// entry (an id evicted without its map entry removed) rather than trusting the
    /// map blindly — a wrong index here would corrupt a different flow.
    private func index(of id: UUID) -> Int? {
        guard let absolute = positions[id] else { return nil }
        let index = absolute - droppedFromFront
        guard flows.indices.contains(index), flows[index].id == id else { return nil }
        return index
    }

    private func bodySize(of flow: Flow) -> Int {
        (flow.request.body?.count ?? 0) + (flow.response?.body?.count ?? 0)
    }

    /// Load recent persisted flows into the ring once (at boot), so captures
    /// survive a relaunch. No broadcast — these are history, not live updates.
    func loadPersisted(limit: Int) {
        guard !didLoadPersisted, flows.isEmpty, let persistence else { return }
        didLoadPersisted = true
        flows = persistence.recent(limit: limit).reversed() // ring is oldest-first
        reindex()
        // Seeded from the ring so the sidebar has something immediately; the history
        // pass replaces it (see `seedAggregatesFromHistory`), because these counts are
        // claimed to be over everything retained and the ring is a tenth of it.
        aggregates = FlowAggregates()
        for flow in flows { aggregates.contribute(flow) }
    }

    /// Replace the ring-seeded counts with counts over every retained row.
    ///
    /// Separate from `loadPersisted` and `await`-ed off the actor because it decodes
    /// the whole table (bounded by its row cap) and the boot path must not sit behind
    /// it. Until it lands, `flowAggregates()` reports `coversHistory == false` rather
    /// than letting a partial count pass for the total.
    func seedAggregatesFromHistory() async {
        guard let persistence, !aggregatesCoverHistory else { return }
        let fromHistory = await Self.aggregateHistory(persistence: persistence)
        // Re-fold the flows that are *not* on disk. Only completed flows are persisted,
        // so anything still in flight would otherwise be dropped from the counts by
        // this replacement — including, on a busy boot, every exchange started since.
        var merged = fromHistory
        for flow in flows where flow.completedAt == nil { merged.contribute(flow) }
        aggregates = merged
        aggregatesCoverHistory = true
    }

    @concurrent private static func aggregateHistory(persistence: FlowPersistence) async -> FlowAggregates {
        persistence.aggregate()
    }

    /// The sidebar's counts, and whether they cover history yet.
    func flowAggregates() -> (aggregates: FlowAggregates, coversHistory: Bool) {
        (aggregates, aggregatesCoverHistory)
    }

    /// Retract flows the durable store pruned on its own schedule. Called from the
    /// persistence queue, so it hops back onto the actor.
    func forgetPruned(_ flows: [Flow]) {
        for flow in flows {
            // A pruned row that is still in the ring has not left the capture — the
            // ring copy is reachable and `recent`/`page` still return it.
            guard positions[flow.id] == nil else { continue }
            aggregates.retract(flow)
        }
    }

    /// Rebuild `positions` from scratch — only for wholesale replacements of the
    /// ring (boot load), never on the hot path.
    private func reindex() {
        droppedFromFront = 0
        slimCursor = 0
        positions = Dictionary(
            flows.enumerated().map { ($0.element.id, $0.offset) },
            uniquingKeysWith: { _, last in last }
        )
    }

    var isRecording: Bool { recording }

    /// Record that a client opened a connection to the proxy. Called from the
    /// server's child-channel initializer for every accepted connection. Only LAN
    /// peers count (loopback = this Mac). Broadcasts the new total on a first sight.
    func noteConnection(remoteIP: String) {
        guard SourceDevice.kind(forIP: remoteIP) == .lan else { return }
        guard connectedLANIPs.insert(remoteIP).inserted else { return }
        let count = connectedLANIPs.count
        for continuation in deviceCountContinuations.values { continuation.yield(count) }
    }

    var connectedDeviceCount: Int { connectedLANIPs.count }

    /// Live count of connected LAN devices. Seeds the current value on subscribe,
    /// then yields on each newly-seen device (and on `clear()`).
    func connectedDeviceCountStream() -> AsyncStream<Int> {
        let id = UUID()
        // A count only ever needs its newest value — an older one is worthless, so
        // buffering one and replacing it is both bounded and lossless in practice.
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            continuation.yield(connectedLANIPs.count)
            deviceCountContinuations[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.dropDeviceCountContinuation(id) }
            }
        }
    }

    private func dropDeviceCountContinuation(_ id: UUID) {
        deviceCountContinuations[id] = nil
    }

    /// Pause/resume capture. Paused: new flows are dropped, but updates to
    /// already-recorded flows (in-flight completions) still land, so a request
    /// captured before pausing never gets stuck open.
    func setRecording(_ on: Bool) {
        recording = on
    }

    /// Insert a new flow or replace an existing one with the same id
    /// (we upsert twice per exchange: once on request start, once on completion).
    /// `force` bypasses a capture pause — explicit actions like replay always
    /// record their result.
    func upsert(_ flow: Flow, force: Bool = false) {
        var flow = flow
        if let idx = index(of: flow.id) {
            // Attribution, once known, sticks: the resolver may backfill the
            // source app concurrently with forwarding, and the relay's later
            // upserts (streaming updates, completion) carry whatever it knew at
            // start — a nil there must not erase an answer that already landed.
            if flow.sourceApp == nil { flow.sourceApp = flows[idx].sourceApp }
            bodyBytes += bodySize(of: flow) - bodySize(of: flows[idx])
            // Same flow, new state: its error-ness and its attribution can both have
            // changed since it was counted (pending isn't an error; the 500 it becomes
            // is), so the old contribution comes out before the new one goes in.
            aggregates.retract(flows[idx])
            aggregates.contribute(flow)
            flows[idx] = flow
            // A replacement can re-attach bodies behind the slim cursor (e.g. a
            // WebSocket frame landing on an old flow) — pull the cursor back so
            // those bytes are reclaimable again.
            if idx < slimCursor, bodySize(of: flow) > 0 { slimCursor = idx }
        } else {
            guard recording || force else { return }
            positions[flow.id] = droppedFromFront + flows.count
            flows.append(flow)
            aggregates.contribute(flow)
            bodyBytes += bodySize(of: flow)
            if flows.count > capacity {
                let overflow = flows.count - capacity
                for evicted in flows.prefix(overflow) {
                    bodyBytes -= bodySize(of: evicted)
                    positions[evicted.id] = nil
                    // Leaving the ring is not leaving the capture: a completed flow is
                    // on disk and still retained. One that never completed was never
                    // saved, so this is where it actually disappears.
                    if evicted.completedAt == nil { aggregates.retract(evicted) }
                }
                flows.removeFirst(overflow)
                droppedFromFront += overflow
                slimCursor = max(0, slimCursor - overflow)
            }
        }
        // Persist only completed exchanges — in-flight flows live in the ring, so
        // streaming/WebSocket flows write once at the end, not per chunk/frame.
        if flow.completedAt != nil {
            persistence?.save(flow)
        }
        enforceBodyBudget()
        broadcast(flow)
    }

    /// Drop in-memory bodies from the oldest flows until the ring is under its byte
    /// budget. Slimmed flows keep all metadata; with a store behind them their bodies
    /// stay on disk and `hydrated` re-attaches them on a detail/replay/export read.
    ///
    /// **It runs without a store too**, and that is a fix rather than a widening. The
    /// guard used to be `persistence != nil`, on sound reasoning — with nothing to
    /// hydrate from, dropping a body loses it — but the consequence was that an
    /// embedder (`ProxyEngine(persistFlows: false)`) had *no* body bound at all: the
    /// budget was a no-op and the ring held every byte it was ever handed. Measured at
    /// a 20 000-flow ring with 32 KB bodies: **625 MB live**, against 61 MB for the
    /// same traffic with a store. The bound has to exist; what the missing store
    /// changes is that the drop is a loss, so it is *recorded* as one
    /// (`Flow.evictingBodies`) instead of leaving a flow claiming it had no body.
    private func enforceBodyBudget() {
        guard bodyBytes > bodyBudget else { return }
        let recoverable = persistence != nil
        var idx = slimCursor
        while idx < flows.count, bodyBytes > bodyBudget {
            let existing = flows[idx]
            // Only slim completed flows (an in-flight body isn't on disk yet, and
            // isn't finished being recorded either) that still carry bytes.
            if existing.completedAt != nil {
                let size = bodySize(of: existing)
                if size > 0 {
                    flows[idx] = recoverable ? existing.strippingBodies() : existing.evictingBodies()
                    bodyBytes -= size
                }
            }
            idx += 1
        }
        // Advance past the leading run that can never yield bytes again: completed
        // and body-free. An in-flight flow parks the cursor (it becomes slimmable
        // only once completed), which is fine — it either completes or evicts.
        while slimCursor < flows.count,
              flows[slimCursor].completedAt != nil,
              bodySize(of: flows[slimCursor]) == 0 {
            slimCursor += 1
        }
    }

    /// Backfill the originating app on an already-recorded flow, preserving
    /// everything the exchange has recorded since. The resolver races the relay's
    /// response upserts once resolution runs concurrently with forwarding, so a
    /// whole-`Flow` re-upsert here could overwrite a completed outcome with a
    /// stale pending copy — this mutates only the attribution.
    func attributeSourceApp(id: UUID, _ app: SourceApp) {
        guard let idx = index(of: id), flows[idx].sourceApp == nil else { return }
        flows[idx].sourceApp = app
        // A completed flow already persisted without the attribution — refresh it.
        if flows[idx].completedAt != nil {
            persistence?.save(flows[idx])
        }
        broadcast(flows[idx])
    }

    func recent(limit: Int) -> [Flow] {
        Array(flows.suffix(max(0, limit)).reversed())
    }

    /// Newest-first flows matching `query`, capped at `limit`.
    ///
    /// **The scan runs off the actor**, over a snapshot of the ring. That snapshot is
    /// free — `flows` is an `Array` of value types, so handing it out is a COW
    /// reference bump, not 2000 copies — and holding the actor for it was not:
    ///
    /// | on a full (2000) ring | measured |
    /// |---|---|
    /// | one host-filtered scan | 2.1 ms |
    /// | one upsert, quiet | 0.014 ms |
    /// | one upsert, while scans run | **1.8 ms** |
    ///
    /// Every exchange upserts at least twice (pending → completed), a streaming one
    /// more, a WebSocket once per frame — and all of them queue on this actor. An
    /// agent polling `get_recent_flows` with a filter therefore put a ~2 ms stall in
    /// front of *every capture write*, a 127× slowdown on work that touches no shared
    /// state at all. The snapshot removes the contention outright; results are
    /// identical, since the scan sees exactly the ring as of the call either way.
    ///
    /// A body predicate (`FlowQuery.needsBodies`) is the one that can touch disk: a
    /// candidate is hydrated *only after* it has passed every cheap predicate, and
    /// the returned flow is the ring's own (body-free) copy either way — so the list
    /// read's "never hydrate" contract (invariant I2) holds and a body search still
    /// sees flows the ring has slimmed. Narrow it with `host`/`url_contains`/`since`
    /// to keep the number of hydrations small.
    ///
    /// **It reads through to disk when the ring runs out.** It did not, and that was a
    /// silent hole rather than a thin answer: the ring holds `FlowLimits.memoryRing`
    /// flows and the store an order of magnitude more, so nine of every ten persisted
    /// exchanges could not be found by any
    /// search — while `flow(id:)` and `recentHydrated` resolved them perfectly well. An
    /// agent could hold an id that worked and search for the same exchange to `[]`, and
    /// `[]` reads exactly like "that traffic never happened".
    func recent(matching query: FlowQuery, limit: Int) async -> [Flow] {
        guard !query.isEmpty else { return recent(limit: limit) }
        return await Self.scan(
            snapshot: flows, query: query, limit: max(0, limit), persistence: persistence
        ).flows
    }

    /// `recent(matching:)` plus what the answer is worth: whether history was reached
    /// for, whether that scan hit its row budget, and how much history exists.
    ///
    /// A separate entry point rather than a wider return type on the plain read: most
    /// callers want the flows, and the one that reports to an agent wants the bound.
    func search(matching query: FlowQuery, limit: Int) async -> FlowSearchResult {
        guard !query.isEmpty else {
            return FlowSearchResult(
                flows: recent(limit: limit),
                budgetExhausted: false,
                storedFlowCount: persistence?.approximateStoredRowCount
            )
        }
        var result = await Self.scan(
            snapshot: flows, query: query, limit: max(0, limit), persistence: persistence
        )
        result.storedFlowCount = persistence?.approximateStoredRowCount
        return result
    }

    /// The whole of `recent(matching:)`'s work, off the actor.
    ///
    /// `@concurrent` rather than `Task.detached`. Both leave the actor, which is the
    /// point; only this one stays in the task tree, and a detached child ignores
    /// cancellation — so an MCP client that hung up mid-search left the scan running
    /// to the end and the awaiting task waiting for it. `wait_for_flow` cancels
    /// exactly this way (`MCPHTTPHandler` cancels `inFlight` on `channelInactive`),
    /// so the cancellation path is real, not theoretical.
    ///
    /// Newest-first with an early exit at `limit`, so a narrow filter over a full ring
    /// costs a partial walk and copies only what it returns.
    @concurrent private static func scan(
        snapshot: [Flow], query: FlowQuery, limit: Int, persistence: FlowPersistence?
    ) async -> FlowSearchResult {
        var matches: [Flow] = []
        matches.reserveCapacity(min(limit, 64))
        for flow in snapshot.reversed() {
            guard matches.count < limit else { break }
            if Task.isCancelled { break }
            guard query.matchesMetadata(flow) else { continue }
            // Cheap predicates first, always: hydration is a synchronous SQLite blob
            // read, and one per non-matching flow is the cost this ordering avoids.
            guard !query.needsBodies || query.matchesBodies(Self.hydrated(flow, from: persistence))
            else { continue }
            matches.append(flow)
        }
        // The ring answered in full — history holds nothing newer than what was just
        // walked, so there is nothing to read through for.
        guard matches.count < limit, let persistence, !Task.isCancelled else {
            return FlowSearchResult(flows: matches, budgetExhausted: false, storedFlowCount: nil)
        }
        // Everything in the ring is excluded by id rather than by time: the ring's
        // oldest flow is not necessarily the newest row on disk (an in-flight exchange
        // stays in memory while newer ones complete and persist), so a timestamp cut
        // would either skip rows or repeat them.
        let older = persistence.scan(
            matching: query,
            limit: limit - matches.count,
            excluding: Set(snapshot.map(\.id)),
            rowBudget: historyScanRowBudget
        )
        return FlowSearchResult(
            flows: matches + older.flows,
            budgetExhausted: older.budgetExhausted,
            storedFlowCount: nil
        )
    }

    /// One page of the capture, newest-first, resuming after `cursor`.
    ///
    /// **Nothing in Loom pages it today, and that is worth stating rather than implying.**
    /// This used to open "the read a windowed list surface uses instead of holding every
    /// flow — it keeps the rows it can draw plus a prefetch margin and asks for more as
    /// it scrolls", which describes a main window that does not exist: `AppFeature`
    /// restores history with a single `flowPage(nil, displayCap, .all)` at boot and then
    /// holds the whole capture, and `FlowPage.nextCursor` / `totalCount` are read only by
    /// `FlowPageTests`.
    ///
    /// It is kept, and not because the window might page one day. That one boot call is
    /// the only read that has to merge the ring and the store *in order*, which is the
    /// hard half below; `recent(matching:)` can concatenate because it stops at a limit,
    /// and this cannot. The cursor is what makes the merge expressible at all — see
    /// `FlowCursor` for why an offset into a list the capture keeps prepending to
    /// silently skips and repeats rows — so the resumable shape comes almost free with
    /// the correct one. If the window is ever paged, this is what it will call; until
    /// then, treat the cursor half as tested-but-unexercised rather than as evidence
    /// that a paged surface exists somewhere.
    ///
    /// Ring first, then history, merged. Two things make the merge non-obvious and
    /// both are load-bearing:
    ///
    /// - **The ring is scanned in full rather than walked until the cursor.** Insertion
    ///   order is *almost* `startedAt` order and not quite: a long-running exchange is
    ///   appended when it starts and can still be in flight while hundreds of newer
    ///   ones complete around it. Stopping early on position would skip it.
    /// - **The two halves are merged by the ordering, not concatenated.** A ring flow
    ///   older than a persisted one is possible for the same reason, so appending
    ///   "ring, then disk" would emit rows out of order at the seam.
    func page(
        after cursor: FlowCursor?, limit: Int, matching query: FlowQuery = .all
    ) async -> FlowPage {
        let limit = max(0, limit)
        guard limit > 0 else { return FlowPage(flows: [], nextCursor: cursor, totalCount: totalRetained()) }
        let page = await Self.assemblePage(
            snapshot: flows, cursor: cursor, query: query, limit: limit, persistence: persistence
        )
        return FlowPage(flows: page.flows, nextCursor: page.nextCursor, totalCount: totalRetained())
    }

    /// Everything retained and reachable, in memory and on disk, counted once.
    ///
    /// `upsert` persists a flow only once it has completed, so the two sets overlap
    /// exactly on completed flows: the stored count plus the ring's *in-flight* flows
    /// is the total, with nothing double-counted. Nil without a store — the ring is
    /// then the whole truth and the caller already has its count.
    ///
    /// Approximate by an insert-or-replace's worth, and cheap *because* of it — see
    /// `FlowPersistence.approximateStoredRowCount`, which is the one read here that
    /// deliberately does not enter the persistence queue.
    private func totalRetained() -> Int? {
        guard let persistence else { return nil }
        return persistence.approximateStoredRowCount + flows.count(where: { $0.completedAt == nil })
    }

    @concurrent private static func assemblePage(
        snapshot: [Flow],
        cursor: FlowCursor?,
        query: FlowQuery,
        limit: Int,
        persistence: FlowPersistence?
    ) async -> (flows: [Flow], nextCursor: FlowCursor?) {
        var fromRing: [Flow] = []
        for flow in snapshot {
            if Task.isCancelled { break }
            if let cursor, !cursor.precedes(flow) { continue }
            guard query.matchesMetadata(flow) else { continue }
            if query.needsBodies, !query.matchesBodies(Self.hydrated(flow, from: persistence)) { continue }
            fromRing.append(flow)
        }
        fromRing.sort(by: FlowCursor.isOrderedBefore)
        var page = Array(fromRing.prefix(limit))

        // History is asked **on every page, from the caller's cursor** — not only when
        // the ring came up short, and not from the ring's oldest row.
        //
        // The tempting version fills from the ring, then asks disk to continue after
        // the last ring row. It assumes the ring is a *prefix* of the global ordering,
        // and it isn't: the ring is the most recently *inserted* flows, while the order
        // here is `startedAt` with the id as tiebreak. When a burst shares a timestamp —
        // a page load firing a dozen requests inside one millisecond, h2 multiplexing
        // more — the ring's rows are an arbitrary subset of that instant's ids, not its
        // highest ones, so continuing after the ring's minimum skips every disk row
        // sorting above it. Caught by `aPageBoundaryInsideOneInstantIsStable`, which
        // returned 11 of 20 flows.
        //
        // Asking both halves for the same range and merging needs no such assumption.
        // The cost is one indexed, limited query per page even when the ring could have
        // answered — which is the right trade for a read that must not silently skip.
        if let persistence, !Task.isCancelled {
            let older = persistence.scan(
                matching: query,
                after: cursor,
                limit: limit,
                excluding: Set(snapshot.map(\.id)),   // the ring's copy is the fresher one
                rowBudget: historyScanRowBudget
            )
            page.append(contentsOf: older.flows)
            page.sort(by: FlowCursor.isOrderedBefore)
            page = Array(page.prefix(limit))
        }
        // A short page means the end: neither half had anything left to fill it with.
        let next = page.count < limit ? nil : page.last.map(FlowCursor.init)
        return (page, next)
    }

    /// How many history rows one search may examine.
    ///
    /// Above the table's own cap, so in practice a search reads all of it and the
    /// budget only ever fires if the cap is raised. It exists because the scan runs on
    /// `FlowPersistence`'s serial queue — the same queue batched writes flush on — and
    /// an unbounded walk there would put a long read in front of capture flushes. When
    /// it does fire, the caller is told (`FlowSearchResult.budgetExhausted`), because a
    /// truncated search that looks exhaustive is the bug this whole path exists to fix.
    static let historyScanRowBudget = 25_000

    func clear() {
        flows.removeAll()
        positions.removeAll()
        aggregates.removeAll()
        droppedFromFront = 0
        bodyBytes = 0
        slimCursor = 0
        connectedLANIPs.removeAll()
        for continuation in deviceCountContinuations.values { continuation.yield(0) }
        for continuation in clearedContinuations.values { continuation.yield(()) }
        persistence?.deleteAll()
    }

    /// Fires on every `clear()`, so a surface holding its own copy of the flow list
    /// (the main window) drops it when *anyone* clears — including an agent over
    /// MCP, which the window would otherwise never hear about.
    func clearedStream() -> AsyncStream<Void> {
        let id = UUID()
        // "the capture was discarded" carries no payload, so one pending signal is
        // as informative as ten.
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            clearedContinuations[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.dropClearedContinuation(id) }
            }
        }
    }

    private func dropClearedContinuation(_ id: UUID) {
        clearedContinuations[id] = nil
    }

    /// Drain the persistence write queue so completed flows saved just before
    /// quit actually reach disk (saves are `queue.async`). No-op without a store.
    func flush() {
        persistence?.flush()
    }

    /// Terminal-state every still-open flow (`.pending` or mid-`.streaming`) as
    /// failed, so a quit with requests in flight doesn't silently drop them:
    /// completed flows already persist as they finish, but in-flight ones live
    /// only in the ring. Preserves a streaming flow's partial response, persists
    /// each, and broadcasts the transition. Returns how many were finalized.
    @discardableResult
    func finalizeInFlight(reason: String, at date: Date = Date()) -> Int {
        var finalized = 0
        for idx in flows.indices {
            let partial: CapturedResponse?
            switch flows[idx].outcome {
            case .pending: partial = nil
            case let .streaming(response): partial = response
            case .completed, .failed: continue // already terminal
            }
            flows[idx].outcome = .failed(FlowError(reason), at: date, partialResponse: partial)
            finalized += 1
            persistence?.save(flows[idx])
            broadcast(flows[idx])
        }
        return finalized
    }

    /// A flow by id, with bodies re-attached from disk when the in-memory copy is
    /// body-free — i.e. a flow reloaded from a prior session (or, once Layer 2
    /// lands, slimmed by the ring budget). Detail/replay/diff read through here, so
    /// they always see full bodies without knowing the flow was ever slimmed.
    func flow(id: UUID) async -> Flow? {
        let persistence = persistence
        if let index = index(of: id) {
            let flow = flows[index]
            // Still carrying its bodies (or has none on disk to fetch) — no disk.
            guard flow.request.body == nil, flow.response?.body == nil, persistence != nil else { return flow }
            // Slimmed by the body budget: hydrate off the actor so the blob read
            // doesn't stall capture upserts (Flow is a value; the snapshot is safe).
            return await Self.hydratedOffActor(flow, persistence: persistence)
        }
        // Not in the ring — but the durable store keeps an order of magnitude more
        // rows, so read through to it. Without this the store is effectively
        // write-only past the ring: `get_flow_detail` / `diff_flows` / `replay`
        // answer "no flow with id X" for a flow Loom still has on disk, and an
        // agent holding a legitimate id (from an earlier list, a `replayedFrom`
        // link, an exported HAR) concludes the exchange never happened.
        // Off-actor for the same reason as above.
        guard persistence != nil else { return nil }
        return await Self.persistedFlow(id: id, persistence: persistence)
    }

    /// The two off-actor reads `flow(id:)` needs. `@concurrent` for the reason
    /// `matchingBodies` gives: leaving the actor was always the point, leaving the
    /// task tree never was.
    @concurrent private static func hydratedOffActor(
        _ flow: Flow, persistence: FlowPersistence?
    ) async -> Flow {
        hydrated(flow, from: persistence)
    }

    @concurrent private static func persistedFlow(
        id: UUID, persistence: FlowPersistence?
    ) async -> Flow? {
        persistence?.flow(id: id)
    }

    /// Recent flows with bodies re-attached — for exports (HAR) that need the full
    /// payload. The plain `recent` stays body-free for cheap list/summary reads.
    ///
    /// Tops up from the durable store when the ring holds fewer than `limit`:
    /// "export the last 5000" must not quietly hand back the 2000 that happen to
    /// be in memory while the rest sit on disk.
    ///
    /// Only the ring snapshot happens on the actor. The hydration — one blob read
    /// per slimmed flow, multi-MB `Data` copies included — and the disk top-up run
    /// off it, because a 1000-flow HAR export used to hold the actor for the whole
    /// assembly and queue every capture upsert behind it.
    func recentHydrated(limit: Int) async -> [Flow] {
        await Self.hydrate(recent(limit: limit), upTo: limit, persistence: persistence)
    }

    /// `@concurrent`, for the reason `matchingBodies` gives — and here cancellation
    /// buys the most: this is the HAR-export assembly, up to `limit` multi-MB blob
    /// reads, and it was the one detached task large enough that abandoning the
    /// export still paid for all of it.
    @concurrent private static func hydrate(
        _ fromRing: [Flow], upTo limit: Int, persistence: FlowPersistence?
    ) async -> [Flow] {
        let hydratedRing = fromRing.map { Self.hydrated($0, from: persistence) }
        guard let persistence, hydratedRing.count < limit, !Task.isCancelled else { return hydratedRing }
        let seen = Set(hydratedRing.map(\.id))
        let older = persistence.recent(limit: limit)
            .lazy
            .filter { !seen.contains($0.id) }
            .map { Self.hydrated($0, from: persistence) }
            .prefix(limit - hydratedRing.count)
        return hydratedRing + older
    }

    /// Re-attach persisted bodies when the in-memory flow carries none. A live
    /// flow that still holds its bodies is returned untouched; a genuinely
    /// body-less flow stays body-less (the columns are nil too).
    ///
    /// `nonisolated` and fed an explicit persistence handle: callers run it off
    /// the actor (persistence serializes on its own queue, so it needs no actor
    /// protection, and blocking the actor on `queue.sync` was the whole problem).
    private nonisolated static func hydrated(_ flow: Flow, from persistence: FlowPersistence?) -> Flow {
        guard flow.request.body == nil, flow.response?.body == nil,
              let persistence, let bodies = persistence.bodies(id: flow.id),
              bodies.request != nil || bodies.response != nil
        else { return flow }
        return flow.attachingBodies(request: bodies.request, response: bodies.response)
    }

    var count: Int { flows.count }

    /// Everything retained, ring **and** store, or nil when nothing is persisted.
    ///
    /// The ring's `count` plateaus at its capacity, so as a "how much have I captured"
    /// answer it stops moving after the first 2 000 exchanges and reads as a capture
    /// that stalled. This is the number that keeps going up, and the one every read
    /// path can still resolve an id from (`flow(id:)`, `recent(matching:)` and the HAR
    /// export all fall through to the store).
    ///
    /// Read without entering the persistence queue, which is load-bearing rather than
    /// incidental: this is on `ProxyEngine.status()`, and holding this actor for a
    /// SQLite transaction puts that stall in front of every capture write. See
    /// `FlowPersistence.approximateStoredRowCount`.
    var retainedCount: Int? { persistence?.approximateStoredRowCount }

    /// A new live subscription. Every `broadcast(_:)` (from `upsert` /
    /// `finalizeInFlight`) yields here; see `FlowProviding.flowStream()` for the
    /// emission contract. Unbuffered — a late subscriber misses prior emissions.
    func stream() -> AsyncStream<Flow> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingOldest(Self.streamBuffer)) { continuation in
            continuations[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.dropContinuation(id) }
            }
        }
    }

    private func dropContinuation(_ id: UUID) {
        continuations[id] = nil
        droppedEmissions[id] = nil
    }
}
