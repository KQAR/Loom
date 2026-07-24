import Foundation
import LoomSharedModels

/// In-memory, bounded store of write-action audit entries plus a fan-out of live
/// updates — the audit-trail sibling of `FlowStore`. Actor-isolated so the MCP
/// writer and the UI reader stay race-free.
actor AuditStore {
    private var entries: [AuditEntry] = []
    private let capacity: Int
    private var continuations: [UUID: AsyncStream<AuditEntry>.Continuation] = [:]
    /// Durable backing (nil in tests / store-less embedders).
    private let persistence: AuditPersistence?
    private var didLoadPersisted = false

    init(capacity: Int = 1000, persistence: AuditPersistence? = nil) {
        self.capacity = capacity
        self.persistence = persistence
    }

    /// Load persisted entries into the ring once, on the first read, so the trail
    /// survives a relaunch. Lazy (not tied to `start()`) because the audit log is
    /// queryable even when the proxy isn't running.
    private func loadPersistedIfNeeded() {
        guard !didLoadPersisted, entries.isEmpty, let persistence else { return }
        didLoadPersisted = true
        entries = persistence.recent(limit: capacity).reversed() // ring is oldest-first
    }

    /// Append one entry: bound the ring, persist, and fan out to live subscribers.
    func record(_ entry: AuditEntry) {
        loadPersistedIfNeeded()
        entries.append(entry)
        if entries.count > capacity {
            entries.removeFirst(entries.count - capacity)
        }
        persistence?.save(entry)
        for continuation in continuations.values {
            continuation.yield(entry)
        }
    }

    /// Newest-first, up to `limit`.
    func recent(limit: Int) -> [AuditEntry] {
        loadPersistedIfNeeded()
        return Array(entries.suffix(max(0, limit)).reversed())
    }

    /// Drain the persistence write queue so entries recorded just before quit
    /// reach disk. No-op without a store.
    func flush() {
        persistence?.flush()
    }

    /// A new live subscription. Every `record` yields here. Unbuffered — a late
    /// subscriber misses prior entries (seed from `recent`).
    func stream() -> AsyncStream<AuditEntry> {
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
