import Foundation
import LoomSharedModels
import Synchronization

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
///
/// The state lives *inside* the `Mutex`, which is why this type is plainly
/// `Sendable` rather than `@unchecked Sendable`: there is no longer a mutable
/// property the compiler has to be told to ignore.
final class RefusalLog: Sendable {
    static let shared = RefusalLog()

    /// Small on purpose. These are read to answer "what just happened to my
    /// client", which is a question about the last few seconds; anything older is
    /// covered by the total and by the log stream.
    static let capacity = 20

    private struct State {
        var entries: [ConnectionRefusal] = []
        var total = 0
    }

    private let state = Mutex(State())

    func record(_ refusal: ConnectionRefusal) {
        state.withLock {
            $0.total += 1
            $0.entries.insert(refusal, at: 0)
            if $0.entries.count > Self.capacity {
                $0.entries.removeLast($0.entries.count - Self.capacity)
            }
        }
    }

    /// Newest-first refusals plus the all-time count.
    func snapshot() -> (recent: [ConnectionRefusal], total: Int) {
        state.withLock { ($0.entries, $0.total) }
    }

    /// For tests, and for an embedder that restarts the engine in one process.
    func reset() {
        state.withLock { $0 = State() }
    }
}
