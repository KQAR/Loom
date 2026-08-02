import Foundation
import LoomSharedModels

/// Bounded record of connections the listeners accepted and then refused.
///
/// Written from channel handlers (any event loop) and read from the engine actor,
/// so it is lock-based rather than an actor: recording must not suspend a
/// handler, and the whole operation is a prepend to a small array.
///
/// **Bounded by construction**, like every other in-memory collection in the
/// engine: the ring keeps `capacity` entries and `total` counts everything ever
/// recorded, so a client failing on every connection shows up as a large total
/// rather than as an unbounded array.
final class RefusalLog: @unchecked Sendable {
    static let shared = RefusalLog()

    /// Small on purpose. These are read to answer "what just happened to my
    /// client", which is a question about the last few seconds; anything older is
    /// covered by the total and by the log stream.
    static let capacity = 20

    private let lock = NSLock()
    private var entries: [ConnectionRefusal] = []
    private var total = 0

    func record(_ refusal: ConnectionRefusal) {
        lock.lock()
        defer { lock.unlock() }
        total += 1
        entries.insert(refusal, at: 0)
        if entries.count > Self.capacity { entries.removeLast(entries.count - Self.capacity) }
    }

    /// Newest-first refusals plus the all-time count.
    func snapshot() -> (recent: [ConnectionRefusal], total: Int) {
        lock.lock()
        defer { lock.unlock() }
        return (entries, total)
    }

    /// For tests, and for an embedder that restarts the engine in one process.
    func reset() {
        lock.lock()
        defer { lock.unlock() }
        entries.removeAll()
        total = 0
    }
}
