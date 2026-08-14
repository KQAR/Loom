import Foundation
import LoomSharedModels
import NIOCore
import Synchronization

/// The relayed tunnels that are open right now, so decrypting a host can end them.
///
/// **Why this exists.** A tunnel Loom relays is a byte splice: the requests inside it
/// are ciphertext, so they produce no rows and never will. Scope changes only reach
/// *new* connections, and an HTTP client reuses the one it has — measured on a real
/// app, seven requests over two connections, and a home screen refreshed repeatedly
/// on a connection opened minutes earlier. So an operator who clicks Decrypt watches
/// nothing happen, for as long as the client's pool holds that socket: the setting is
/// correct and the surface is empty, which is the failure this whole area exists to
/// remove.
///
/// The fix uses the client's own reconnect logic rather than working around it. Loom
/// holds one end of that socket, so it can close it; every HTTP client must handle a
/// server closing a connection, and the one it opens next is intercepted.
///
/// Three rules.
///
/// **Only relayed tunnels are registered.** A decrypted connection is already being
/// read — closing it would cost the client a reconnect and buy nothing.
///
/// **Closing is the client's problem to recover from, and that is stated rather than
/// hidden.** Most clients retry an idempotent request; one that had a POST in flight
/// sees a reset. That is a real cost, accepted because it lands in the second after
/// someone asked to decrypt this host — a consequence the operator can attribute,
/// which a connection dropped at a random later moment is not. `intercept_host`
/// reports the count so the choice is visible to an agent too.
///
/// **Entries remove themselves.** Registration hangs the removal off the channel's
/// own `closeFuture`, so a tunnel that ends normally — which is nearly all of them —
/// leaves nothing behind, and the registry's size tracks live tunnels rather than
/// tunnels ever opened.
final class RelayedTunnelRegistry: Sendable {
    /// Process-wide, like `TunneledHostLog`: the splice happens deep in a channel
    /// pipeline that has no reference to the engine, and threading one through every
    /// handler to reach a set of open sockets is the plumbing this avoids. Tests take
    /// their own instance.
    static let shared = RelayedTunnelRegistry()

    /// Keyed by host, lowercased. The port is carried on the entry rather than in the
    /// key: a scope decision is about a host, and a client that opened tunnels to
    /// :443 and :8443 means both when it says "decrypt this".
    private struct Entry {
        let host: String
        let port: Int
        let channel: any Channel
    }

    private let entries = Mutex<[ObjectIdentifier: Entry]>([:])

    init() {}

    /// Record a tunnel for as long as it is open.
    func register(host: String, port: Int, client: any Channel) {
        let id = ObjectIdentifier(client)
        entries.withLock { $0[id] = Entry(host: host.lowercased(), port: port, channel: client) }
        // Self-removing, so the registry cannot outlive the sockets it names.
        // `self` rather than capturing the `Mutex` — a non-copyable stored property
        // cannot be captured out of the type, and the registry is process-wide, so
        // there is nothing here for a strong reference to keep alive that would not
        // be alive anyway.
        client.closeFuture.whenComplete { [self] _ in
            entries.withLock { _ = $0.removeValue(forKey: id) }
        }
    }

    /// Close every open relayed tunnel whose host matches `pattern`, and say how many.
    ///
    /// Takes a **glob**, not a hostname, because that is what an include entry is:
    /// decrypting `*.corp` has to end the tunnels to `api.corp` and `cdn.corp` as
    /// well, or the one write the operator made covers a domain while its live
    /// connections stay opaque.
    @discardableResult
    func closeTunnels(matching pattern: String) -> Int {
        closeTunnels { Glob.matches(pattern, $0.host) }
    }

    /// Close every open relayed tunnel that `scope` would now decrypt.
    ///
    /// `setSSLScope` is a wholesale replace, so it cannot name one host the way
    /// `interceptHost` does. Closing every tunnel whose host `shouldIntercept`
    /// would now read is the same rule applied to the resulting scope: a host
    /// still excluded, or still unnamed, reconnects into another relay and the
    /// close would cost the client a reconnect for nothing.
    @discardableResult
    func closeTunnels(interceptedBy scope: SSLScope) -> Int {
        closeTunnels { scope.shouldIntercept(host: $0.host) }
    }

    /// The close is `nil`-promised and the entry is removed by the channel's own
    /// `closeFuture`, not here — a close that is already in flight, or a channel that
    /// died a microsecond ago, must not be a second removal path with its own
    /// ordering. The count is of tunnels this call asked to close.
    private func closeTunnels(where matches: (Entry) -> Bool) -> Int {
        // Snapshot under the lock, close outside it: `close` hops to each channel's
        // event loop and may complete inline, and running a completion that re-enters
        // this lock while it is held is the deadlock the two-section shape avoids
        // (ProxyCore/CLAUDE.md § Sendable escape hatches).
        let doomed = entries.withLock { $0.values.filter(matches) }
        for entry in doomed {
            Log.tls.error("""
            Closing the relayed tunnel to \(entry.host, privacy: .public):\(entry.port, privacy: .public) \
            because that host is now decrypted. The client will reconnect and the new connection is \
            intercepted; a request in flight on this one will be retried by the client or fail.
            """)
            entry.channel.close(promise: nil)
        }
        return doomed.count
    }

    /// Live tunnels, for tests and for anything that wants to know without closing.
    var count: Int { entries.withLock(\.count) }

    /// For tests, and for an embedder that restarts the engine in one process.
    func reset() {
        entries.withLock { $0.removeAll() }
    }
}
