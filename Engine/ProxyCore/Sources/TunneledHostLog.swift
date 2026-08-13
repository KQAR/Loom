import Foundation
import LoomSharedModels
import Synchronization

/// Bounded record of the hosts Loom relayed without reading.
///
/// This is the discoverability half of a whitelist SSL scope. With `include`
/// empty by default, a blind-tunnelled origin leaves *nothing* on any read
/// surface — no flow, no request, no error — which is byte-for-byte the same
/// answer an agent gets when the client never ran at all. Charles gets away with
/// its empty whitelist because it still lists the CONNECT row for a human to
/// right-click; this is the equivalent fact, aggregated, for both audiences.
///
/// Written from channel handlers (any event loop) and read from the engine actor,
/// so it is lock-based rather than an actor: recording must not suspend a handler,
/// and the whole operation is one dictionary upsert. Process-wide `shared` for the
/// same reason `RefusalLog` is — the handlers reach it without threading an extra
/// dependency through four initialisers — with a plain `init` for tests.
///
/// **Bounded by construction**, like every other in-memory collection in the
/// engine: `capacity` hosts are kept, the least recently active is evicted first,
/// and `evicted` counts what went so a truncated list is never a silent one.
final class TunneledHostLog: Sendable {
    static let shared = TunneledHostLog()

    /// One entry per origin, not per connection, so this holds a browsing session's
    /// worth of distinct hosts rather than a page load's worth of sockets.
    static let capacity = 256

    private struct State {
        var hosts: [String: TunneledHost] = [:]
        var evicted = 0
    }

    private let state = Mutex(State())

    /// Fold one unread connection into the host's entry.
    func record(
        host: String, port: Int, reason: TunnelReason, detail: String? = nil, at date: Date = Date()
    ) {
        let key = "\(host.lowercased()):\(port)"
        state.withLock {
            if var existing = $0.hosts[key] {
                existing.connections += 1
                existing.lastSeen = date
                // Latest reason wins — see `TunneledHost.reason` — and the detail
                // travels with it rather than outliving the reason that explained it.
                existing.reason = reason
                existing.detail = detail
                $0.hosts[key] = existing
                return
            }
            $0.hosts[key] = TunneledHost(
                host: host, port: port, firstSeen: date, lastSeen: date, reason: reason, detail: detail
            )
            guard $0.hosts.count > Self.capacity else { return }
            // Evict least-recently-active. A dictionary has no order to drop from,
            // so this is an O(n) scan — paid only on a host that is both new and
            // over the cap, i.e. once per new origin past 256.
            if let stalest = $0.hosts.min(by: { $0.value.lastSeen < $1.value.lastSeen })?.key {
                $0.hosts.removeValue(forKey: stalest)
                $0.evicted += 1
            }
        }
    }

    /// Every entry, most recent activity first, plus how many were evicted.
    func snapshot() -> (hosts: [TunneledHost], evicted: Int) {
        state.withLock {
            ($0.hosts.values.sorted { $0.lastSeen > $1.lastSeen }, $0.evicted)
        }
    }

    /// Drop entries the given scope would now decrypt.
    ///
    /// A host stays listed only while it is still an *open question*. Once someone
    /// intercepts it, offering "intercept this" again is noise — and worse, it reads
    /// as the action having failed. Entries whose reason a scope change cannot fix
    /// (`.notTLSOrHTTP`, a failed leaf mint) survive regardless: they are still
    /// unread, and pretending otherwise is how the SSH-tunnel case becomes
    /// invisible a second time.
    static func pending(_ hosts: [TunneledHost], under scope: SSLScope) -> [TunneledHost] {
        hosts.filter { entry in
            guard entry.interceptable else { return true }
            return !scope.shouldIntercept(host: entry.host)
        }
    }

    /// For tests, and for an embedder that restarts the engine in one process.
    func reset() {
        state.withLock { $0 = State() }
    }
}
