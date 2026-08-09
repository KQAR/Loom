import Foundation
import Synchronization

/// Which protocol era the requests reaching this endpoint actually spoke, and who
/// spoke them.
///
/// ## Why this exists
///
/// Loom serves two revisions at once (`MCPProtocol`), and the old one is a standing
/// tax: a second set of error semantics, a second dispatch path, and a test suite
/// pinning both. ROADMAP § Structured Channel states when it may be dropped, and one
/// of the two conditions is *"a release has shipped with no legacy dispatch
/// recorded"*.
///
/// Nothing recorded it. `MCPProtocol.decide` picks an era for every request and the
/// answer was thrown away, so that condition could never be evaluated — which makes a
/// compatibility layer permanent by default, the exact failure the condition was
/// written to prevent. This is what makes it decidable.
///
/// ## Why it is not one counter
///
/// "Legacy" covers two different facts and only one of them is evidence:
///
/// - **`initialize`** is a handshake only the old revision has. A client sending it
///   *is* an old client, and it names itself while doing so.
/// - **A bare request** — no `_meta`, no header — is legacy by fallback. It might be
///   an old client, or a proxy that stripped the metadata, or a `curl` someone typed.
///   It proves nothing.
///
/// The asymmetry has a practical consequence that is easy to walk into: the handshake
/// happens **once per client connection**, and over stateless HTTP everything after it
/// is a bare request. So a legacy client that connected before this app launched sends
/// traffic all day and never appears as evidence — measured on Claude Code, which
/// re-used its connection across several restarts of this app and showed up only in
/// `legacyBareRequests`. Reading the tally therefore means restarting the *client*, not
/// merely exercising it; `ProtocolTrafficRender`'s `unknown` reason says so.
///
/// A single count would almost never reach zero (bare requests keep arriving), the
/// condition would never fire, and the tax would stay — with telemetry that made it look
/// measured. So the reasons are counted apart and the condition reads only the first.
///
/// ## What it deliberately does not do
///
/// No persistence, no timestamps beyond "last seen", nothing per-request. This
/// answers one question at release time — *is anything still on the old revision, and
/// what is it* — and a bounded in-memory tally answers it. Everything here is capped
/// (§ "bound what's in memory"), and truncation is reported rather than silent.
final class MCPEraLog: Sendable {
    /// Why an era was chosen. These are exactly `MCPProtocol.decide`'s branches, so a
    /// new branch there is a new case here rather than a silent bucket.
    enum Reason: String, Sendable, CaseIterable {
        /// Modern: the request carried a protocol version in `_meta`.
        case modernMeta
        /// Modern: no `_meta`, but the header declared a revision we serve. Rare —
        /// `validateModern` rejects the header/body mismatch this usually indicates.
        case modernHeader
        /// Legacy, **and evidence**: `initialize` is the old revision's handshake.
        case legacyHandshake
        /// Legacy by fallback: nothing declared an era. Not evidence — see the type's
        /// doc comment.
        case legacyBareRequest

        var isLegacy: Bool {
            switch self {
            case .modernMeta, .modernHeader: false
            case .legacyHandshake, .legacyBareRequest: true
            }
        }
    }

    /// One client, as it identified itself. Named clients are the useful half: the
    /// retirement condition's *other* half is "every client Loom ships a manifest for
    /// negotiates modern", and that is a question about names, not counts.
    struct Client: Sendable, Equatable {
        var name: String
        var version: String?
        var requests: Int
        var lastSeen: Date
    }

    struct Snapshot: Sendable {
        var counts: [Reason: Int]
        /// Clients seen on each era, keyed by `name@version`.
        var modernClients: [Client]
        var legacyClients: [Client]
        /// Distinct clients dropped by the cap, per era — never silently.
        var modernClientsOmitted: Int
        var legacyClientsOmitted: Int

        /// The number the retirement condition reads: requests that prove an old
        /// client exists. Bare fallback requests are excluded on purpose.
        var legacyHandshakes: Int { counts[.legacyHandshake] ?? 0 }
    }

    /// Distinct client identities kept per era. A client identity comes off the wire,
    /// so it is attacker-controlled in principle; the cap is what keeps a hostile or
    /// buggy caller from growing this without bound.
    static let maxClients = 16

    private struct State {
        var counts: [Reason: Int] = [:]
        var modern: [String: Client] = [:]
        var legacy: [String: Client] = [:]
        var modernOmitted = 0
        var legacyOmitted = 0
    }

    private let state = Mutex(State())

    /// Record one dispatched request.
    ///
    /// `client` is whatever the request said about itself — `clientInfo` from a legacy
    /// `initialize`'s params or from a modern `_meta`. Nil when it said nothing, which
    /// is normal for a bare request and is itself part of the answer.
    func record(reason: Reason, client: MCPClientIdentity?, at now: Date = Date()) {
        state.withLock { state in
            state.counts[reason, default: 0] += 1
            guard let client else { return }
            let key = client.key
            let isLegacy = reason.isLegacy
            var bucket = isLegacy ? state.legacy : state.modern
            if var existing = bucket[key] {
                existing.requests += 1
                existing.lastSeen = now
                bucket[key] = existing
            } else if bucket.count < Self.maxClients {
                bucket[key] = Client(
                    name: client.name, version: client.version, requests: 1, lastSeen: now
                )
            } else {
                if isLegacy { state.legacyOmitted += 1 } else { state.modernOmitted += 1 }
                return
            }
            if isLegacy { state.legacy = bucket } else { state.modern = bucket }
        }
    }

    func snapshot() -> Snapshot {
        state.withLock { state in
            // Busiest first: with a cap of 16 the ordering is the only affordance for
            // "which of these matters", and a release decision is about the loud one.
            func sorted(_ clients: [String: Client]) -> [Client] {
                clients.values.sorted {
                    $0.requests == $1.requests ? $0.name < $1.name : $0.requests > $1.requests
                }
            }
            return Snapshot(
                counts: state.counts,
                modernClients: sorted(state.modern),
                legacyClients: sorted(state.legacy),
                modernClientsOmitted: state.modernOmitted,
                legacyClientsOmitted: state.legacyOmitted
            )
        }
    }
}

/// How a client named itself, from a legacy `initialize`'s `clientInfo` or a modern
/// request's `_meta`. One parser for both, because "who is calling" must not mean two
/// different things depending on which era asked.
struct MCPClientIdentity: Sendable, Equatable {
    var name: String
    var version: String?

    var key: String { version.map { "\(name)@\($0)" } ?? name }

    /// Nil when the object is absent or nameless — an unnamed client is not an
    /// identity, and inventing one ("unknown") would make the client list unable to
    /// answer the question it exists for.
    init?(_ raw: Any?) {
        guard let object = raw as? [String: Any],
              let name = object["name"] as? String,
              !name.isEmpty
        else { return nil }
        self.name = name
        version = object["version"] as? String
    }
}
