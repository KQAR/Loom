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
///
/// `requestWritten` is the other half of the retry decision (RFC 9110 §9.2.2): a
/// request whose final flush never succeeded cannot have been processed, so it is
/// safe to re-send whatever its method; one that was fully written may have been
/// acted on, and only an idempotent method may be retried past that point.
struct UpstreamAttemptFailure: Error {
    let underlying: Error
    let didYield: Bool
    let requestWritten: Bool
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
        /// How this exchange is travelling, evaluated **lazily at head time**
        /// rather than at arm time. On a fresh connection the TLS handshake has
        /// not finished when the exchange arms — NIOSSL buffers the request write
        /// until it has — so reading the negotiated version any earlier reads nil
        /// on exactly the connections it is most interesting for.
        let transport: @Sendable () -> FlowTransport
        let completion: @Sendable (Result<UpstreamAttemptEnd, UpstreamAttemptFailure>) -> Void
        var didYield = false
        /// Response body bytes as they arrived from the socket, still encoded.
        /// Counted upstream of the decompressor and reported once, with the end.
        var encodedBodyBytes: Int?
        var reusable = false
        /// An interim (1xx) head was seen and its message-end is still owed. The
        /// decoder delivers `100 Continue` as a complete head+end message, and
        /// treating that end as *the* end released the connection into the pool
        /// while the final response was still on the wire — the next lease could
        /// then be handed the previous request's response.
        var awaitingInterimEnd = false
    }

    private let armed = Mutex<Armed?>(nil)
    /// A failure that arrived while nothing was armed — a fresh connection whose
    /// TLS handshake ran to failure before `arm` — held so the arm that follows
    /// fails with the *real* error (naming the alert, the identity) instead of a
    /// bare `connectionClosed` reconstructed from `isActive`.
    private let pendingFailure = Mutex<Error?>(nil)

    /// True while an exchange is in flight. Read by the pool to refuse pooling a
    /// connection that is somehow still busy.
    var isBusy: Bool { armed.withLock { $0 != nil } }

    func arm(
        continuation: AsyncThrowingStream<UpstreamResponseEvent, Error>.Continuation,
        methodIsHead: Bool,
        transport: @escaping @Sendable () -> FlowTransport = { FlowTransport() },
        completion: @escaping @Sendable (Result<UpstreamAttemptEnd, UpstreamAttemptFailure>) -> Void
    ) {
        armed.withLock {
            $0 = Armed(
                continuation: continuation, methodIsHead: methodIsHead,
                transport: transport, completion: completion
            )
        }
        // A failure that beat the arm fails the exchange now, with its own words.
        if let earlier = pendingFailure.withLock({ failure -> Error? in
            let current = failure
            failure = nil
            return current
        }) {
            fail(earlier)
        }
    }

    // MARK: - Called from the relay, on the event loop

    func receivedHead(_ head: HTTPResponseHead, headers: [HeaderPair], httpVersion: String) {
        // An interim response (1xx, RFC 9110 §15.2) is not the response — it is
        // swallowed here, never yielded, and its `.end` is swallowed too (see
        // `completeSuccessfully`). 101 is deliberately not treated as interim:
        // it terminates HTTP framing, and since the forwarder strips `Upgrade`
        // as hop-by-hop an origin sending one is answering a request Loom never
        // made — it falls through as a final head whose connection can't be
        // reused (`responseIsReusable` has no case that accepts it).
        let status = head.status.code
        if (100..<200).contains(status), status != 101 {
            armed.withLock {
                guard var current = $0 else { return }
                current.awaitingInterimEnd = true
                $0 = current
            }
            return
        }
        // Take the continuation out from under the lock before yielding: yielding
        // can run consumer code, and running it while holding this lock would put a
        // stranger's execution inside our critical section.
        let armedNow: (continuation: AsyncThrowingStream<UpstreamResponseEvent, Error>.Continuation,
                       transport: @Sendable () -> FlowTransport)? = armed.withLock {
            guard var current = $0 else { return nil }
            current.reusable = Self.responseIsReusable(head, methodIsHead: current.methodIsHead)
            current.didYield = true
            // The final head arriving is what settles any owed interim end —
            // whether or not the decoder delivered one.
            current.awaitingInterimEnd = false
            $0 = current
            return (current.continuation, current.transport)
        }
        guard let armedNow else { return }
        // Before the head, so a consumer that records the head already has the
        // connection's facts in hand. `Content-Encoding` is read off the *raw*
        // head — `headers` has been sanitized, because the decompressor has
        // already inflated the body and the header no longer describes it — and
        // this is the only place the origin's own encoding is still visible.
        var transport = armedNow.transport()
        transport.responseContentEncoding = head.headers[canonicalForm: "Content-Encoding"]
            .first.map { $0.lowercased() }
        armedNow.continuation.yield(.transport(transport))
        armedNow.continuation.yield(
            .head(statusCode: Int(head.status.code), httpVersion: httpVersion, headers: headers)
        )
    }

    /// The encoded size of the response body, counted on the socket side of the
    /// decompressor. Recorded rather than yielded here: it is reported with the
    /// end so it cannot land before a body chunk it is meant to describe.
    func receivedEncodedBodyBytes(_ bytes: Int) {
        armed.withLock {
            guard var current = $0 else { return }
            current.encodedBodyBytes = bytes
            $0 = current
        }
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
        // The end paired with an interim head belongs to the 1xx message, not to
        // the exchange — swallow it and keep waiting for the final response.
        let interim = armed.withLock { armed -> Bool in
            guard var current = armed, current.awaitingInterimEnd else { return false }
            current.awaitingInterimEnd = false
            armed = current
            return true
        }
        if interim { return }
        guard let current = take() else { return }
        // The second (and last) transport instalment: a byte count is only a
        // number once the body has finished, so it could never have ridden the
        // head. The consumer merges it over what the head carried.
        if let encoded = current.encodedBodyBytes {
            current.continuation.yield(.transport(FlowTransport(responseEncodedBodyBytes: encoded)))
        }
        current.completion(.success(current.reusable ? .reusable : .mustClose))
    }

    /// The attempt failed. Disarms. With nothing armed the error is *held* rather
    /// than dropped — a fresh connection's TLS handshake can run to failure before
    /// the exchange arms, and that error names what actually happened.
    func fail(_ error: Error) {
        guard let current = take() else {
            pendingFailure.withLock { failure in
                if failure == nil { failure = error }
            }
            return
        }
        // `requestWritten` is conservative here — the slot never sees the write
        // side. `attempt` re-stamps it with the measured value before the failure
        // reaches the retry decision.
        current.completion(.failure(UpstreamAttemptFailure(
            underlying: error, didYield: current.didYield, requestWritten: true
        )))
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
    ///
    /// 1xx is deliberately absent from the bodyless set: interim responses are
    /// swallowed in `receivedHead` and never reach this predicate, and a 101 that
    /// does reach it must answer `false` — after Switching Protocols the bytes on
    /// the wire are no longer HTTP/1.1 messages, so there is nothing to pool.
    static func responseIsReusable(_ head: HTTPResponseHead, methodIsHead: Bool) -> Bool {
        guard head.isKeepAlive else { return false }
        let status = head.status.code
        let bodyless = methodIsHead || status == 204 || status == 304
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
    /// The origin's address, snapshotted at connect time rather than read off the
    /// channel later. `Channel.remoteAddress` is safe to read off the loop, but a
    /// closed channel stops answering — and a transport reading nil for the one
    /// exchange that failed is the reading you most wanted.
    let remoteAddress: String?
    /// Filled in by `UpstreamTLSObserver` when the handshake completes. A box
    /// rather than a `let` because the handler goes into the pipeline inside
    /// `channelInitializer`, which runs before this object exists — the same
    /// construction cycle `UpstreamInactiveNotifier` exists for.
    let tlsInfo: UpstreamTLSInfoBox

    private struct State {
        var closed = false
        /// Bumped on every lease and release, so a previously scheduled idle
        /// expiry can tell it is stale without anything having to cancel it.
        var idleGeneration = 0
    }

    private let state = Mutex(State())

    init(
        key: UpstreamPoolKey,
        channel: Channel,
        slot: UpstreamExchangeSlot,
        tlsInfo: UpstreamTLSInfoBox = UpstreamTLSInfoBox()
    ) {
        self.key = key
        self.channel = channel
        self.slot = slot
        self.tlsInfo = tlsInfo
        remoteAddress = channel.remoteAddress.map(Self.describe)
    }

    /// `"93.184.216.34:443"` — `SocketAddress`'s own `description` wraps the
    /// address in its type name (`[IPv4]93.184.216.34:443`), which is noise on a
    /// surface where the reader wants to paste the address somewhere.
    private static func describe(_ address: SocketAddress) -> String {
        guard let ip = address.ipAddress else { return String(describing: address) }
        guard let port = address.port else { return ip }
        // Bracket an IPv6 literal, per RFC 3986 §3.2.2, or the colons run together.
        return ip.contains(":") ? "[\(ip)]:\(port)" : "\(ip):\(port)"
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

    /// Close every parked connection presenting the named mTLS identity.
    ///
    /// The pool's key carries the identity's *label*, and an in-place edit of the
    /// PKCS#12 behind a label changes neither the label nor the key — so without
    /// this, a connection handshaken under the old certificate keeps being leased
    /// for as long as traffic keeps it from idling out. `ClientCertificateConfig`
    /// already drops its cached `NIOSSLContext` on mutation for exactly this
    /// reason; the pool holds the other copy of the same stale state.
    func drain(identityLabel: String) {
        let parked = state.withLock { state -> [UpstreamConnection] in
            var evicted: [UpstreamConnection] = []
            for (key, bucket) in state.idle where key.identity == identityLabel {
                evicted.append(contentsOf: bucket)
                state.totalIdle -= bucket.count
                state.idle[key] = nil
            }
            return evicted
        }
        for connection in parked { connection.close() }
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
