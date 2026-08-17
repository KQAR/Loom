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
        var clientSuccesses: [String: SuccessEvidence] = [:]
        var evicted = 0
        var clientSuccessesEvicted = 0
    }

    private struct SuccessEvidence {
        var count: Int
        var firstSeen: Date
        var lastSeen: Date
    }

    private let state = Mutex(State())

    /// Fold one unread connection into the host's entry.
    func record(
        host: String, port: Int, reason: TunnelReason, detail: String? = nil, at date: Date = Date()
    ) {
        if reason == .clientHandshakeFailed {
            recordClientFailure(
                host: host, port: port, code: .clientHandshakeFailed,
                detail: detail, at: date
            )
            return
        }
        let key = "\(host.lowercased()):\(port)"
        state.withLock {
            if var existing = $0.hosts[key] {
                guard existing.reason == reason else {
                    guard date >= existing.lastSeen else { return }
                    existing.reason = reason
                    existing.detail = detail
                    existing.lastSeen = date
                    existing.connections = 1
                    // `clientTLS` is independent historical evidence. A later codec
                    // or scope verdict must not erase it.
                    $0.hosts[key] = existing
                    return
                }
                existing.connections += 1
                if date >= existing.lastSeen {
                    existing.lastSeen = date
                    existing.detail = detail
                }
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

    /// Record one failed client-facing TLS attempt without losing success evidence.
    func recordClientFailure(
        host: String, port: Int, code: FlowError.Code,
        detail: String? = nil, tlsAlert: TLSClientAlert? = nil, at date: Date = Date()
    ) {
        let key = "\(host.lowercased()):\(port)"
        state.withLock {
            if var existing = $0.hosts[key], existing.reason == .clientHandshakeFailed {
                var observation = existing.clientTLS ?? TunneledHost.ClientTLS(
                    failureCount: existing.connections,
                    lastFailureAt: existing.lastSeen,
                    lastFailureCode: code,
                    lastFailureAlert: tlsAlert ?? detail.flatMap(TLSClientAlert.parse)
                )
                observation.failureCount += 1
                if date >= observation.lastFailureAt {
                    observation.lastFailureAt = date
                    observation.lastFailureCode = code
                    observation.lastFailureAlert = tlsAlert ?? detail.flatMap(TLSClientAlert.parse)
                    existing.detail = detail
                }
                existing.connections = observation.failureCount
                existing.lastSeen = max(existing.lastSeen, date)
                existing.clientTLS = observation
                $0.hosts[key] = existing
                return
            }
            let successes = $0.clientSuccesses.removeValue(forKey: key)
            $0.hosts[key] = TunneledHost(
                host: host, port: port,
                firstSeen: min(successes?.firstSeen ?? date, date),
                lastSeen: max(successes?.lastSeen ?? date, date),
                reason: .clientHandshakeFailed, detail: detail,
                clientTLS: TunneledHost.ClientTLS(
                    successCount: successes?.count ?? 0,
                    lastFailureAt: date,
                    lastSuccessAt: successes?.lastSeen,
                    lastFailureCode: code,
                    lastFailureAlert: tlsAlert ?? detail.flatMap(TLSClientAlert.parse)
                )
            )
            evictIfNeeded(&$0)
        }
    }

    /// Retain a success beside the failures already observed for this origin.
    ///
    /// Healthy origins are not inserted: this log remains bounded by problems the
    /// operator actually encountered rather than becoming a second host census.
    func recordClientSuccess(host: String, port: Int, at date: Date = Date()) {
        let key = "\(host.lowercased()):\(port)"
        state.withLock {
            guard var existing = $0.hosts[key],
                  existing.reason == .clientHandshakeFailed,
                  var observation = existing.clientTLS
            else {
                if var successes = $0.clientSuccesses[key] {
                    successes.count += 1
                    successes.lastSeen = max(successes.lastSeen, date)
                    $0.clientSuccesses[key] = successes
                } else {
                    $0.clientSuccesses[key] = SuccessEvidence(
                        count: 1, firstSeen: date, lastSeen: date
                    )
                    evictSuccessIfNeeded(&$0)
                }
                return
            }
            observation.successCount += 1
            let lastSuccess = max(observation.lastSuccessAt ?? .distantPast, date)
            observation.lastSuccessAt = lastSuccess
            existing.lastSeen = max(existing.lastSeen, date)
            existing.clientTLS = observation
            $0.hosts[key] = existing
        }
    }

    /// A decoded HTTP/2 stream proves the prior connection-level codec verdict no
    /// longer describes this host. A TLS handshake alone cannot prove that.
    func clearProtocolErrorAfterDecodedStream(host: String, port: Int) {
        let key = "\(host.lowercased()):\(port)"
        state.withLock {
            guard $0.hosts[key]?.reason == .protocolError else { return }
            $0.hosts.removeValue(forKey: key)
        }
    }

    /// Every entry, most recent activity first, plus how many were evicted.
    func snapshot() -> (
        hosts: [TunneledHost], evicted: Int, clientSuccessesEvicted: Int
    ) {
        state.withLock {
            (
                $0.hosts.values.sorted { $0.lastSeen > $1.lastSeen },
                $0.evicted,
                $0.clientSuccessesEvicted
            )
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

    /// Forget everything seen. Three callers: `clearFlows` (the session's capture and
    /// this log are one answer — see there), tests, and an embedder that restarts the
    /// engine in one process.
    func reset() {
        state.withLock { $0 = State() }
    }

    private func evictIfNeeded(_ state: inout State) {
        guard state.hosts.count > Self.capacity else { return }
        if let stalest = state.hosts.min(by: { $0.value.lastSeen < $1.value.lastSeen })?.key {
            state.hosts.removeValue(forKey: stalest)
            state.evicted += 1
        }
    }

    private func evictSuccessIfNeeded(_ state: inout State) {
        guard state.clientSuccesses.count > Self.capacity else { return }
        if let stalest = state.clientSuccesses.min(by: {
            $0.value.lastSeen < $1.value.lastSeen
        })?.key {
            if let removed = state.clientSuccesses.removeValue(forKey: stalest) {
                state.clientSuccessesEvicted += removed.count
            }
        }
    }
}
