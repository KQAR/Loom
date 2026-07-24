import Foundation
import SharedModels

/// In-memory, bounded store of flows plus a fan-out of live updates.
/// Actor-isolated so the NIO handlers and the UI/MCP readers stay race-free.
actor FlowStore {
    private var flows: [Flow] = []
    private let capacity: Int
    private var continuations: [UUID: AsyncStream<Flow>.Continuation] = [:]
    private var recording = true
    /// Durable backing (nil in tests). Only completed flows are written.
    private let persistence: FlowPersistence?
    private var didLoadPersisted = false

    init(capacity: Int = 2000, persistence: FlowPersistence? = nil) {
        self.capacity = capacity
        self.persistence = persistence
    }

    /// Load recent persisted flows into the ring once (at boot), so captures
    /// survive a relaunch. No broadcast — these are history, not live updates.
    func loadPersisted(limit: Int) {
        guard !didLoadPersisted, flows.isEmpty, let persistence else { return }
        didLoadPersisted = true
        flows = persistence.recent(limit: limit).reversed() // ring is oldest-first
    }

    var isRecording: Bool { recording }

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
        if let idx = flows.firstIndex(where: { $0.id == flow.id }) {
            flows[idx] = flow
        } else {
            guard recording || force else { return }
            flows.append(flow)
            if flows.count > capacity {
                flows.removeFirst(flows.count - capacity)
            }
        }
        // Persist only completed exchanges — in-flight flows live in the ring, so
        // streaming/WebSocket flows write once at the end, not per chunk/frame.
        if flow.completedAt != nil {
            persistence?.save(flow)
        }
        for continuation in continuations.values {
            continuation.yield(flow)
        }
    }

    func recent(limit: Int) -> [Flow] {
        Array(flows.suffix(max(0, limit)).reversed())
    }

    func clear() {
        flows.removeAll()
        persistence?.deleteAll()
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
            for continuation in continuations.values {
                continuation.yield(flows[idx])
            }
        }
        return finalized
    }

    func flow(id: UUID) -> Flow? {
        flows.first { $0.id == id }
    }

    var count: Int { flows.count }

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
