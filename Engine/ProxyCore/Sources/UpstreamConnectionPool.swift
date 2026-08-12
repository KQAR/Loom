import Foundation
import Synchronization
import NIOCore
import NIOHTTP1
import LoomSharedModels

/// Which upstream connections are interchangeable.
///
/// The mTLS identity is part of the key and not an afterthought: two requests to
/// the same origin that present *different* client certificates are two different
/// authenticated sessions, and handing one the other's socket would send a request
/// under a credential its caller never chose.
struct UpstreamPoolKey: Hashable, Sendable {
    let host: String
    let port: Int
    let isTLS: Bool
    /// Label of the client identity presented on this connection, or nil for none.
    let identity: String?
}

/// How one attempt on an upstream connection ended, from the pool's point of view.
enum UpstreamAttemptEnd: Sendable {
    /// The response completed and the connection is framed well enough to carry
    /// another request (see `UpstreamExchangeSlot.responseIsReusable`).
    case reusable
    /// The response completed but this connection cannot be reused — `Connection:
    /// close`, HTTP/1.0, or a body delimited by the close itself.
    case mustClose
}

/// An attempt that failed before it produced a complete response.
///
/// `didYield` is the whole reason this is a type rather than a bare `Error`: an
/// attempt on a *leased* connection that failed having emitted nothing is
/// indistinguishable, from the caller's side, from never having been made — so it
/// can be retried on a fresh socket. One that already yielded a head cannot,
/// because the consumer has seen part of a response that will never finish.
struct UpstreamAttemptFailure: Error {
    let underlying: Error
    let didYield: Bool
}

/// The handoff between the event-loop-confined response relay and the `Task` driving
/// one forward.
///
/// Armed before a request is written and disarmed exactly once — when the response
/// ends, or when the connection fails or goes away underneath it. Everything the
/// relay would otherwise have held as mutable handler state lives here instead,
/// which is what lets the relay itself be plainly `Sendable`.
///
/// The relay *yields* through this slot; it never *terminates* the caller's stream.
/// That split is deliberate: a failure with nothing yielded is a retry candidate,
/// and a relay that had already finished the stream with the error would have
/// spent the outcome the retry decision needs.
final class UpstreamExchangeSlot: Sendable {
    private struct Armed {
        let continuation: AsyncThrowingStream<UpstreamResponseEvent, Error>.Continuation
        let methodIsHead: Bool
        let completion: @Sendable (Result<UpstreamAttemptEnd, UpstreamAttemptFailure>) -> Void
        var didYield = false
        var reusable = false
    }

    private let armed = Mutex<Armed?>(nil)

    /// True while an exchange is in flight. Read by the pool to refuse pooling a
    /// connection that is somehow still busy.
    var isBusy: Bool { armed.withLock { $0 != nil } }

    func arm(
        continuation: AsyncThrowingStream<UpstreamResponseEvent, Error>.Continuation,
        methodIsHead: Bool,
        completion: @escaping @Sendable (Result<UpstreamAttemptEnd, UpstreamAttemptFailure>) -> Void
    ) {
        armed.withLock {
            $0 = Armed(continuation: continuation, methodIsHead: methodIsHead, completion: completion)
        }
    }

    // MARK: - Called from the relay, on the event loop

    func receivedHead(_ head: HTTPResponseHead, headers: [HeaderPair], httpVersion: String) {
        // Take the continuation out from under the lock before yielding: yielding
        // can run consumer code, and running it while holding this lock would put a
        // stranger's execution inside our critical section.
        let continuation: AsyncThrowingStream<UpstreamResponseEvent, Error>.Continuation? = armed.withLock {
            guard var current = $0 else { return nil }
            current.reusable = Self.responseIsReusable(head, methodIsHead: current.methodIsHead)
            current.didYield = true
            $0 = current
            return current.continuation
        }
        continuation?.yield(.head(statusCode: Int(head.status.code), httpVersion: httpVersion, headers: headers))
    }

    func receivedBody(_ data: Data) {
        let continuation = armed.withLock { armed -> AsyncThrowingStream<UpstreamResponseEvent, Error>.Continuation? in
            guard var current = armed else { return nil }
            current.didYield = true
            armed = current
            return current.continuation
        }
        continuation?.yield(.body(data))
    }

    /// The response ended cleanly. Disarms and reports whether the connection survives.
    func completeSuccessfully() {
        guard let current = take() else { return }
        current.completion(.success(current.reusable ? .reusable : .mustClose))
    }

    /// The attempt failed. Disarms; a no-op if nothing was armed, which is the
    /// ordinary case for a connection that dies while sitting idle in the pool.
    func fail(_ error: Error) {
        guard let current = take() else { return }
        current.completion(.failure(UpstreamAttemptFailure(underlying: error, didYield: current.didYield)))
    }

    private func take() -> Armed? {
        armed.withLock { armed in
            let current = armed
            armed = nil
            return current
        }
    }

    /// Whether a connection that just delivered this response can carry another request.
    ///
    /// Keep-alive alone is not enough. A response with no `Content-Length` and no
    /// chunked framing is delimited by the connection closing, so "the body ended"
    /// and "the socket ended" are the same event and there is nothing left to reuse
    /// — pooling one of those hands the next request a socket that is already
    /// closing, which is the stale-connection failure this pool exists to avoid
    /// rather than cause.
    static func responseIsReusable(_ head: HTTPResponseHead, methodIsHead: Bool) -> Bool {
        guard head.isKeepAlive else { return false }
        let status = head.status.code
        let bodyless = methodIsHead || status == 204 || status == 304 || (100..<200).contains(status)
        if bodyless { return true }
        if head.headers.contains(name: "Content-Length") { return true }
        let encodings = head.headers[canonicalForm: "Transfer-Encoding"]
        return encodings.contains { $0.lowercased() == "chunked" }
    }
}

/// A one-shot, settable callback the response relay fires when its socket dies.
///
/// It exists to break a construction cycle rather than to add indirection: the
/// relay goes into the pipeline inside `channelInitializer`, which runs before
/// there is a `Channel` — and therefore before there is an `UpstreamConnection` for
/// it to evict from the pool.
final class UpstreamInactiveNotifier: Sendable {
    private let action = Mutex<(@Sendable () -> Void)?>(nil)

    func onInactive(_ handler: @escaping @Sendable () -> Void) {
        action.withLock { $0 = handler }
    }

    func fire() {
        let handler = action.withLock { $0 }
        handler?()
    }
}

/// One upstream HTTP/1.1 connection that can serve many exchanges in sequence.
///
/// Escape-hatch kind 3 (see ProxyCore/CLAUDE.md § Sendable escape hatches): every
/// stored property is a `let` or lives inside a `Mutex`, and the hatch exists only
/// because `Channel` — thread-safe in practice, and already treated that way by
/// every `ChannelBox` in this module — carries no `Sendable` conformance.
final class UpstreamConnection: @unchecked Sendable {
    let id = UUID()
    let key: UpstreamPoolKey
    let channel: Channel
    let slot: UpstreamExchangeSlot

    private struct State {
        var closed = false
        /// Bumped on every lease and release, so a previously scheduled idle
        /// expiry can tell it is stale without anything having to cancel it.
        var idleGeneration = 0
    }

    private let state = Mutex(State())

    init(key: UpstreamPoolKey, channel: Channel, slot: UpstreamExchangeSlot) {
        self.key = key
        self.channel = channel
        self.slot = slot
    }

    var isUsable: Bool { state.withLock { !$0.closed } && channel.isActive }

    func close() {
        let shouldClose = state.withLock { state -> Bool in
            guard !state.closed else { return false }
            state.closed = true
            state.idleGeneration += 1
            return true
        }
        if shouldClose { channel.close(promise: nil) }
    }

    /// Bump and return the generation. A caller scheduling an idle expiry keeps the
    /// returned value and compares it when the timer fires.
    func nextIdleGeneration() -> Int {
        state.withLock { state in
            state.idleGeneration += 1
            return state.idleGeneration
        }
    }

    func isIdleGenerationCurrent(_ generation: Int) -> Bool {
        state.withLock { $0.idleGeneration == generation && !$0.closed }
    }
}

/// Keeps upstream connections alive between requests, keyed by origin.
///
/// Without this, every intercepted HTTPS request paid a fresh TCP connect **and a
/// fresh TLS handshake** to the origin — measured against a real test API at ~96 ms
/// per request on top of a 20 ms server round trip, i.e. the proxy costing five
/// times the thing it was proxying. Charles and Proxyman pool; Loom looked slow
/// beside them for exactly this reason and nothing else.
///
/// Bounded on purpose, and every bound is a cap rather than a target: idle
/// connections are a resource held on the *origin's* behalf as much as ours, and an
/// unbounded pool turns a burst of traffic into file descriptors that outlive it.
final class UpstreamConnectionPool: Sendable {
    struct Limits: Sendable {
        /// Idle connections kept per origin. A burst wider than this still runs at
        /// full width — the excess connections are simply closed on release rather
        /// than parked.
        var idlePerKey: Int = 8
        /// Idle connections kept across all origins.
        var totalIdle: Int = 64
        /// How long an idle connection is kept. Comfortably under the 60–75 s most
        /// servers use, because the side that closes first decides whether the next
        /// lease races a FIN.
        var idleTimeout: TimeAmount = .seconds(45)
    }

    /// A pool that never keeps anything — the behaviour Loom had before pooling
    /// existed. For tests that want the old one-connection-per-request shape.
    static var disabled: UpstreamConnectionPool {
        UpstreamConnectionPool(limits: Limits(idlePerKey: 0, totalIdle: 0))
    }

    private struct State {
        var idle: [UpstreamPoolKey: [UpstreamConnection]] = [:]
        var totalIdle = 0
    }

    private let limits: Limits
    private let state = Mutex(State())

    init(limits: Limits = Limits()) {
        self.limits = limits
    }

    /// Take an idle connection for `key`, or nil if there is none worth taking.
    ///
    /// Connections that died while parked are dropped here rather than handed out:
    /// the relay's `channelInactive` normally evicts them, but a FIN that lands
    /// between the eviction and this call is exactly the race a liveness check
    /// costs nothing to lose.
    func lease(_ key: UpstreamPoolKey) -> UpstreamConnection? {
        let (leased, dead) = state.withLock { state -> (UpstreamConnection?, [UpstreamConnection]) in
            guard var bucket = state.idle[key] else { return (nil, []) }
            var dead: [UpstreamConnection] = []
            while let candidate = bucket.popLast() {
                state.totalIdle -= 1
                if candidate.isUsable && !candidate.slot.isBusy {
                    state.idle[key] = bucket.isEmpty ? nil : bucket
                    return (candidate, dead)
                }
                dead.append(candidate)
            }
            state.idle[key] = nil
            return (nil, dead)
        }
        // Closing runs outside the lock: `Channel.close` hops to an event loop, and
        // nothing here should hold a lock across that.
        for connection in dead { connection.close() }
        if let leased { _ = leased.nextIdleGeneration() }
        return leased
    }

    /// Park a connection whose exchange finished cleanly. Over a cap, or on a pool
    /// that has been drained, it is closed instead — a caller never has to ask.
    func release(_ connection: UpstreamConnection) {
        guard connection.isUsable, !connection.slot.isBusy else {
            connection.close()
            return
        }
        let generation = connection.nextIdleGeneration()
        let accepted = state.withLock { state -> Bool in
            guard state.totalIdle < limits.totalIdle else { return false }
            var bucket = state.idle[connection.key] ?? []
            guard bucket.count < limits.idlePerKey else { return false }
            bucket.append(connection)
            state.idle[connection.key] = bucket
            state.totalIdle += 1
            return true
        }
        guard accepted else {
            connection.close()
            return
        }
        connection.channel.eventLoop.scheduleTask(in: limits.idleTimeout) { [weak self] in
            guard let self, connection.isIdleGenerationCurrent(generation) else { return }
            self.forget(connection)
            connection.close()
        }
    }

    /// Drop a connection from the idle set without deciding whether to close it —
    /// called by the relay when a parked connection's socket goes away, where the
    /// close has already happened.
    func forget(_ connection: UpstreamConnection) {
        state.withLock { state in
            guard var bucket = state.idle[connection.key] else { return }
            guard let index = bucket.firstIndex(where: { $0 === connection }) else { return }
            bucket.remove(at: index)
            state.totalIdle -= 1
            state.idle[connection.key] = bucket.isEmpty ? nil : bucket
        }
    }

    /// Close every parked connection. Leased ones are untouched: they belong to an
    /// exchange in flight, and that exchange's own termination path closes them.
    ///
    /// Not terminal — a pool that is drained while the proxy is switched off is
    /// usable again when it is switched back on.
    func drain() {
        let parked = state.withLock { state -> [UpstreamConnection] in
            let all = state.idle.values.flatMap { $0 }
            state.idle = [:]
            state.totalIdle = 0
            return all
        }
        for connection in parked { connection.close() }
    }

    /// Idle connections currently parked — for tests and for reasoning about a leak.
    var idleCount: Int { state.withLock { $0.totalIdle } }
}
