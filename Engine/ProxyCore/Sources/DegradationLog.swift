import Foundation
import LoomSharedModels
import Synchronization

/// Where the engine's fail-open paths report themselves.
///
/// Same shape as `RefusalLog` and `TunneledHostLog`, and for the same reason: a
/// fact that decides whether the operator's picture of Loom is correct must be
/// *reachable from a tool*, not only from `os_log`. See `EngineDegradation` for
/// what each entry means and why the log-only version was not enough.
///
/// Held per engine rather than as a global, so a test's fabricated corruption
/// cannot leak into the next test's status — and so an embedder running two
/// engines gets two answers rather than one merged one.
///
/// Deduplicated by kind and counted. Recording is on whatever thread the failure
/// happened on (a SQLite queue, an event loop, an actor), so the state is behind a
/// `Mutex` and the type is plainly `Sendable`.
final class DegradationLog: Sendable {
    private struct Entry {
        var detail: String
        var firstSeen: Date
        var lastSeen: Date
        var count: Int
    }

    private let entries = Mutex<[EngineDegradation.Kind: Entry]>([:])
    private let now: @Sendable () -> Date

    init(now: @escaping @Sendable () -> Date = { Date() }) {
        self.now = now
    }

    /// Record one occurrence. The newest `detail` wins — the same kind failing for a
    /// changing reason is worth seeing latest-first, and the count says it is not new.
    func record(_ kind: EngineDegradation.Kind, _ detail: String) {
        let at = now()
        entries.withLock { entries in
            if var existing = entries[kind] {
                existing.detail = detail
                existing.lastSeen = at
                existing.count += 1
                entries[kind] = existing
            } else {
                entries[kind] = Entry(detail: detail, firstSeen: at, lastSeen: at, count: 1)
            }
        }
    }

    /// Clear one kind, for a fallback that has since succeeded — a rules file that
    /// wrote after a failed write is no longer degraded, and an entry that outlives
    /// its condition is the same defect as no entry at all, pointed the other way.
    func clear(_ kind: EngineDegradation.Kind) {
        entries.withLock { $0[kind] = nil }
    }

    /// Worst-first is not available (there is no severity order that survives
    /// contact with a real machine), so: most recent first, which is what an
    /// operator reading a list of things that went wrong is looking for.
    var current: [EngineDegradation] {
        entries.withLock { entries in
            entries
                .map { kind, entry in
                    EngineDegradation(
                        kind: kind, detail: entry.detail,
                        firstSeen: entry.firstSeen, lastSeen: entry.lastSeen, count: entry.count
                    )
                }
                .sorted { $0.lastSeen > $1.lastSeen }
        }
    }
}
