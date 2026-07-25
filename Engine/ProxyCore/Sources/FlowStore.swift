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
    /// Push sink for embedders that own storage — fired alongside the stream on
    /// every insert/update. See `FlowObserving`.
    private let observer: FlowObserving?

    init(capacity: Int = 2000, bodyBudget: Int = 64_000_000, persistence: FlowPersistence? = nil, observer: FlowObserving? = nil) {
        self.capacity = capacity
        self.bodyBudget = bodyBudget
        self.persistence = persistence
        self.observer = observer
    }

    /// Fan a flow out to every live `flowStream()` consumer and the push
    /// observer. The single broadcast point so the stream and the sink can never
    /// diverge.
    private func broadcast(_ flow: Flow) {
        for continuation in continuations.values {
            continuation.yield(flow)
        }
        observer?.flowDidUpdate(flow)
    }

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
    }

    /// Rebuild `positions` from scratch — only for wholesale replacements of the
    /// ring (boot load), never on the hot path.
    private func reindex() {
        droppedFromFront = 0
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
        return AsyncStream { continuation in
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
        if let idx = index(of: flow.id) {
            bodyBytes += bodySize(of: flow) - bodySize(of: flows[idx])
            flows[idx] = flow
        } else {
            guard recording || force else { return }
            positions[flow.id] = droppedFromFront + flows.count
            flows.append(flow)
            bodyBytes += bodySize(of: flow)
            if flows.count > capacity {
                let overflow = flows.count - capacity
                for evicted in flows.prefix(overflow) {
                    bodyBytes -= bodySize(of: evicted)
                    positions[evicted.id] = nil
                }
                flows.removeFirst(overflow)
                droppedFromFront += overflow
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

    /// Drop in-memory bodies from the oldest persisted flows until the ring is
    /// under its byte budget. Slimmed flows keep all metadata; their bodies stay
    /// on disk and `hydrated` re-attaches them on a detail/replay/export read.
    /// No-op without a store (nothing to hydrate back from) or when in budget.
    private func enforceBodyBudget() {
        guard persistence != nil, bodyBytes > bodyBudget else { return }
        for idx in flows.indices {
            guard bodyBytes > bodyBudget else { break }
            let existing = flows[idx]
            // Only slim completed flows (an in-flight body isn't on disk yet) that
            // still carry bytes.
            guard existing.completedAt != nil else { continue }
            let size = bodySize(of: existing)
            guard size > 0 else { continue }
            flows[idx] = existing.strippingBodies()
            bodyBytes -= size
        }
    }

    func recent(limit: Int) -> [Flow] {
        Array(flows.suffix(max(0, limit)).reversed())
    }

    /// Newest-first flows matching `query`, capped at `limit`. The scan runs here,
    /// inside the actor, walking the ring newest-first and stopping as soon as
    /// `limit` matches are found — so a narrow filter over a full ring costs a
    /// partial walk and copies only what it returns, instead of handing the caller
    /// every flow to sift.
    func recent(matching query: FlowQuery, limit: Int) -> [Flow] {
        guard !query.isEmpty else { return recent(limit: limit) }
        let limit = max(0, limit)
        var matches: [Flow] = []
        matches.reserveCapacity(min(limit, 64))
        for flow in flows.reversed() {
            guard matches.count < limit else { break }
            if query.matches(flow) { matches.append(flow) }
        }
        return matches
    }

    func clear() {
        flows.removeAll()
        positions.removeAll()
        droppedFromFront = 0
        bodyBytes = 0
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
        return AsyncStream { continuation in
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
    func flow(id: UUID) -> Flow? {
        if let index = index(of: id) { return hydrated(flows[index]) }
        // Not in the ring — but the durable store keeps an order of magnitude more
        // rows, so read through to it. Without this the store is effectively
        // write-only past the ring: `get_flow_detail` / `diff_flows` / `replay`
        // answer "no flow with id X" for a flow Loom still has on disk, and an
        // agent holding a legitimate id (from an earlier list, a `replayedFrom`
        // link, an exported HAR) concludes the exchange never happened.
        return persistence?.flow(id: id)
    }

    /// Recent flows with bodies re-attached — for exports (HAR) that need the full
    /// payload. The plain `recent` stays body-free for cheap list/summary reads.
    ///
    /// Tops up from the durable store when the ring holds fewer than `limit`:
    /// "export the last 5000" must not quietly hand back the 2000 that happen to
    /// be in memory while the rest sit on disk.
    func recentHydrated(limit: Int) -> [Flow] {
        let fromRing = recent(limit: limit).map(hydrated)
        guard let persistence, fromRing.count < limit else { return fromRing }
        let seen = Set(fromRing.map(\.id))
        let older = persistence.recent(limit: limit)
            .lazy
            .filter { !seen.contains($0.id) }
            .map(hydrated)
            .prefix(limit - fromRing.count)
        return fromRing + older
    }

    /// Re-attach persisted bodies when the in-memory flow carries none. A live
    /// flow that still holds its bodies is returned untouched; a genuinely
    /// body-less flow stays body-less (the columns are nil too).
    private func hydrated(_ flow: Flow) -> Flow {
        guard flow.request.body == nil, flow.response?.body == nil,
              let persistence, let bodies = persistence.bodies(id: flow.id),
              bodies.request != nil || bodies.response != nil
        else { return flow }
        return flow.attachingBodies(request: bodies.request, response: bodies.response)
    }

    var count: Int { flows.count }

    /// A new live subscription. Every `broadcast(_:)` (from `upsert` /
    /// `finalizeInFlight`) yields here; see `FlowProviding.flowStream()` for the
    /// emission contract. Unbuffered — a late subscriber misses prior emissions.
    func stream() -> AsyncStream<Flow> {
        let id = UUID()
        return AsyncStream { continuation in
            continuations[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.dropContinuation(id) }
            }
        }
    }

    private func dropContinuation(_ id: UUID) {
        continuations[id] = nil
    }
}
