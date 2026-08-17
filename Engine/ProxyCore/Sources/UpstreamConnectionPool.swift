import Foundation
import Synchronization
import NIOCore
import NIOHTTP1
import NIOHTTP2
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
    /// Whether this exchange asked for HTTP/2 upstream. Part of the key because a
    /// connection that offered `h2` in its ALPN list is not interchangeable with one
    /// that did not — and, for cleartext, because an h2c connection carries a
    /// connection preface an h1 request would land after.
    var preferHTTP2: Bool = false
}

/// What an upstream connection actually ended up speaking. Decided by ALPN for a
/// TLS origin and by prior knowledge for a cleartext one — never assumed from the
/// preference, because an origin is free to answer `http/1.1` to an `h2` offer.
enum UpstreamWireProtocol: Sendable {
    case http1
    case http2
}

/// How one attempt on an upstream connection ended: what the pool must do with the
/// socket, plus the last thing the origin said.
struct UpstreamAttemptEnd: Sendable {
    enum Disposition: Sendable {
        /// The response completed and the connection is framed well enough to carry
        /// another request (see `UpstreamExchangeSlot.responseIsReusable`).
        case reusable
        /// The response completed but this connection cannot be reused — `Connection:
        /// close`, HTTP/1.0, or a body delimited by the close itself.
        case mustClose
    }

    let disposition: Disposition
    /// The origin's trailer field section, or nil when it sent none. It rides the
    /// attempt's end rather than being yielded by the slot because the forwarder —
    /// not the relay — terminates the caller's stream, and the trailers belong to
    /// that terminal event.
    let trailers: [HeaderPair]?
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

    /// Whether this exchange has produced anything yet — a head or a body chunk.
    /// A disarmed slot reads `true`: it has already completed, so the first-byte
    /// watch that reads this has nothing left to worry about. Read by the first-byte
    /// probe to tell "the origin is merely slow" from "nothing is coming".
    var hasYielded: Bool { armed.withLock { $0?.didYield ?? true } }

    /// Fail this exchange only if it has produced nothing yet.
    ///
    /// The first-byte watch and a late head race: the watch must not error an
    /// exchange that already yielded, and the two reads (`hasYielded` then `fail`)
    /// cannot be separate or a head lands between them. One lock, one decision.
    /// - Returns: `true` when the failure was applied.
    @discardableResult
    func failIfSilent(_ error: Error) -> Bool {
        let current: Armed? = armed.withLock { armed in
            guard let current = armed, !current.didYield else { return nil }
            armed = nil
            return current
        }
        guard let current else { return false }
        current.completion(.failure(UpstreamAttemptFailure(
            underlying: error, didYield: false, requestWritten: true
        )))
        return true
    }

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

    /// The response ended cleanly. Disarms and reports whether the connection
    /// survives, along with the trailer section the origin sent (nil for none).
    func completeSuccessfully(trailers: [HeaderPair]? = nil) {
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
        current.completion(.success(UpstreamAttemptEnd(
            disposition: current.reusable ? .reusable : .mustClose, trailers: trailers
        )))
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
    /// The connection-wide exchange slot — **HTTP/1.1 only**, where one exchange at
    /// a time owns the socket. An h2 connection multiplexes, so each stream channel
    /// gets a slot of its own and this one is never armed (which is also what makes
    /// `isBusy` correctly false for a shared connection).
    let slot: UpstreamExchangeSlot
    /// What the connection speaks, once it is known. For h2, `multiplexer` is how a
    /// new stream is opened.
    let negotiated: UpstreamWireProtocol
    let multiplexer: HTTP2StreamMultiplexer?
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
    /// What opening this connection cost. A property of the *connection*, so a
    /// reuse can be told it paid none of it — which is why the exchange, not this
    /// type, decides whether to report it.
    let setup: ConnectionSetup
    /// Connection-level liveness, h2 only. A shared connection is handed out without
    /// being taken, so "is it still there" cannot be answered by taking it — see
    /// `UpstreamHealthProbe` for why a PING and not a timer.
    let probe: UpstreamHealthProbe?

    private struct State {
        var closed = false
        /// Bumped on every lease and release, so a previously scheduled idle
        /// expiry can tell it is stale without anything having to cancel it.
        var idleGeneration = 0
        /// When this connection last carried anything. Monotonic — a wall clock can
        /// step backwards and make an idle connection look freshly used.
        var lastUsedAt: NIODeadline = .now()
        /// How long it had been idle when it was last handed out. Read by the
        /// exchange to decide whether the connection is worth probing first; kept
        /// here because `lease` is the act that destroys the answer.
        var idleBeforeLease: TimeAmount = .zero
        /// Exchanges running on it right now. h2 only, where many share one socket:
        /// an idle expiry must not close a connection carrying a long-lived stream
        /// (an SSE response can go minutes without a new lease).
        var activeExchanges = 0
    }

    private let state = Mutex(State())

    init(
        key: UpstreamPoolKey,
        channel: Channel,
        slot: UpstreamExchangeSlot,
        negotiated: UpstreamWireProtocol = .http1,
        multiplexer: HTTP2StreamMultiplexer? = nil,
        tlsInfo: UpstreamTLSInfoBox = UpstreamTLSInfoBox(),
        setup: ConnectionSetup = ConnectionSetup(),
        probe: UpstreamHealthProbe? = nil
    ) {
        self.key = key
        self.channel = channel
        self.slot = slot
        self.negotiated = negotiated
        self.multiplexer = multiplexer
        self.tlsInfo = tlsInfo
        self.setup = setup
        self.probe = probe
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

    /// True when nothing has run on this connection for `timeout` and nothing is
    /// running on it now. Both halves are needed: a stream can outlive many leases.
    func isIdle(longerThan timeout: TimeAmount) -> Bool {
        state.withLock { state in
            guard state.activeExchanges == 0 else { return false }
            return NIODeadline.now() - state.lastUsedAt >= timeout
        }
    }

    /// Record a hand-out and return how long the connection had been sitting unused.
    ///
    /// The two are one operation on purpose: the lease is what makes the idle
    /// duration unknowable a moment later, so anything that wants to reason about
    /// staleness has to be told at the same instant.
    @discardableResult
    func markLeased() -> TimeAmount {
        state.withLock { state in
            let idle = NIODeadline.now() - state.lastUsedAt
            state.idleBeforeLease = idle
            state.lastUsedAt = .now()
            return idle
        }
    }

    /// How long it had been idle when it was last leased.
    ///
    /// A later `markLeased` overwrites this. Callers that decide whether to probe
    /// must use the value `markLeased` (or `UpstreamConnectionPool.lease`) returned,
    /// not re-read this.
    var idleBeforeLease: TimeAmount { state.withLock { $0.idleBeforeLease } }

    /// How long until this connection has been quiet for `timeout`.
    ///
    /// Nil when something is running now — the watch should wait a full window
    /// rather than try to expire under a live stream. Zero when already past due.
    func remainingIdle(of timeout: TimeAmount) -> TimeAmount? {
        state.withLock { state in
            guard state.activeExchanges == 0 else { return nil }
            let leftover = timeout.nanoseconds - (NIODeadline.now() - state.lastUsedAt).nanoseconds
            return leftover <= 0 ? .nanoseconds(0) : .nanoseconds(leftover)
        }
    }

    /// Mark this connection expired if it is still idle. Sets `closed` so a
    /// concurrent `lease` sees `isUsable == false`. Does not close the channel —
    /// the caller does that after forgetting us from the pool.
    func claimIdleExpiry(after timeout: TimeAmount) -> Bool {
        state.withLock { state in
            guard !state.closed else { return false }
            guard state.activeExchanges == 0 else { return false }
            guard NIODeadline.now() - state.lastUsedAt >= timeout else { return false }
            state.closed = true
            state.idleGeneration += 1
            return true
        }
    }

    /// An exchange is starting on this connection. Counted rather than flagged
    /// because h2 runs several at once, and refreshing the clock here is what stops
    /// an idle timer from firing under a request that has only just gone out.
    func beginExchange() {
        state.withLock { state in
            state.activeExchanges += 1
            state.lastUsedAt = .now()
        }
    }

    /// One exchange finished. Refreshes the idle clock, because a response arriving
    /// *is* the connection being alive — the last thing a stale-detection timer
    /// should ignore.
    func endExchange() {
        state.withLock { state in
            state.lastUsedAt = .now()
            if state.activeExchanges > 0 { state.activeExchanges -= 1 }
        }
    }

    /// Ask the origin whether this connection is still there (h2 only), failing with
    /// `error` when the ACK does not arrive inside `timeout`.
    ///
    /// Nil when there is nothing to ask with — an h1 connection, or an h2 one whose
    /// probe never went into the pipeline. A nil answer means "no evidence either
    /// way", which callers must not read as healthy *or* dead.
    func probeLiveness(timeout: TimeAmount, failing error: @autoclosure @escaping @Sendable () -> Error) -> EventLoopFuture<Void>? {
        guard let probe else { return nil }
        return probe.ping(on: channel.eventLoop, timeout: timeout, failure: error())
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
        ///
        /// **It applies to h2 as well as h1**, and did not until 0.0.28. An h2
        /// connection is shared rather than parked, so `release` re-registered it and
        /// there was nothing to expire it — one sat in the pool for 37 minutes, was
        /// leased, and cost five requests 33–51 s each while TCP retransmitted into a
        /// socket whose peer was long gone. Sharing changes who may use a connection,
        /// not how long it is worth keeping.
        var idleTimeout: TimeAmount = .seconds(45)
        /// Idle time past which a shared h2 connection is PINGed before it is used.
        ///
        /// Well under any NAT or origin reaper, because this is the cheap half of the
        /// fix: one round trip on a connection nobody has touched for a while, against
        /// tens of seconds of TCP retransmission if it turns out to be dead. It buys
        /// nothing for a connection that dies *between* the probe and the write, which
        /// is what `firstByteProbeAfter` is for.
        var livenessProbeAfterIdle: TimeAmount = .seconds(5)
        /// How long a liveness PING may take before the connection is called gone.
        /// Generous for a LAN or a nearby origin, and it is only ever paid on a
        /// connection that was already idle.
        var livenessProbeTimeout: TimeAmount = .seconds(2)
        /// How long an exchange on a *reused* connection waits for its first response
        /// byte before Loom stops assuming the origin is merely slow and PINGs.
        ///
        /// Deliberately not a failure deadline: a slow endpoint is ordinary, and
        /// failing one would trade a real answer for a fast wrong one. The probe is
        /// what turns the wait into evidence — ACK means keep waiting, silence means
        /// the connection is gone and the request can be retried.
        var firstByteProbeAfter: TimeAmount = .seconds(5)
    }

    /// What the pool has had to do about connections that went away, counted for the
    /// log rather than for a tool: an operator reading a 30-second exchange needs to
    /// know whether the pool caught a dead socket, and none of this is a fact about
    /// any one flow. `log stream --predicate 'subsystem == "com.loom"'`, category
    /// `forward`.
    struct Stats: Sendable, Equatable {
        /// Connections closed by the idle timer, h1 and h2 together.
        var idleExpiries = 0
        /// Pre-use PINGs that went unanswered — a connection that would otherwise
        /// have been handed a request.
        var livenessProbeFailures = 0
        /// Exchanges whose first-byte wait expired *and* whose PING then failed, i.e.
        /// a connection that died with a request already on it.
        var deadReuseDetected = 0
    }

    /// A pool that never keeps anything — the behaviour Loom had before pooling
    /// existed. For tests that want the old one-connection-per-request shape.
    static var disabled: UpstreamConnectionPool {
        UpstreamConnectionPool(limits: Limits(idlePerKey: 0, totalIdle: 0))
    }

    private struct State {
        var idle: [UpstreamPoolKey: [UpstreamConnection]] = [:]
        var totalIdle = 0
        /// HTTP/2 connections, which are **shared rather than leased**: a stream is
        /// not the socket, so many exchanges run on one connection at once. Keeping
        /// them in their own map rather than reusing `idle` is what stops the h1
        /// bookkeeping — take-on-lease, park-on-release, an idle timer per parking —
        /// from being quietly wrong for a connection that is never idle between two
        /// requests because it is carrying both.
        var multiplexed: [UpstreamPoolKey: UpstreamConnection] = [:]
    }

    /// Read by the forwarder, which owns the two deadlines that need a channel to
    /// act on (the pre-use probe and the first-byte probe) while the policy behind
    /// them belongs here, with the rest of the reuse rules.
    let limits: Limits
    private let state = Mutex(State())
    private let stats = Mutex(Stats())

    init(limits: Limits = Limits()) {
        self.limits = limits
    }

    var statistics: Stats { stats.withLock { $0 } }

    /// Counted here so every site that discovers a dead connection lands in one
    /// place; the log line is the caller's, because only it knows the origin.
    func recordLivenessProbeFailure() { stats.withLock { $0.livenessProbeFailures += 1 } }
    func recordDeadReuse() { stats.withLock { $0.deadReuseDetected += 1 } }

    /// A hand-out from the pool, carrying the idle duration captured at the same
    /// instant. A shared h2 connection can be leased twice; the second `markLeased`
    /// overwrites the stored snapshot, so anything that decides whether to probe
    /// has to be told now.
    struct Lease: Sendable {
        let connection: UpstreamConnection
        let idle: TimeAmount
    }

    /// Drop a connection the first-byte watch proved dead. Must run before the
    /// retry's `registerMultiplexed`, or that call returns this same socket and
    /// the fresh connect is discarded.
    func evictDeadReuse(_ connection: UpstreamConnection) {
        recordDeadReuse()
        forget(connection)
        connection.close()
    }

    /// Take an idle connection for `key`, or nil if there is none worth taking.
    /// The returned `Lease.idle` is the duration at this instant — do not re-read
    /// `idleBeforeLease` later, a concurrent h2 hand-out overwrites it.
    ///
    /// Connections that died while parked are dropped here rather than handed out:
    /// the relay's `channelInactive` normally evicts them, but a FIN that lands
    /// between the eviction and this call is exactly the race a liveness check
    /// costs nothing to lose.
    func lease(_ key: UpstreamPoolKey) -> Lease? {
        // A multiplexed connection is handed out *without being removed*: the next
        // caller wants the same one, concurrently. A dead one is dropped here for
        // the same reason the h1 path checks liveness — the notifier's eviction and
        // an arriving FIN race, and losing that race costs nothing to check.
        if key.preferHTTP2 {
            let shared = state.withLock { state -> UpstreamConnection? in
                guard let existing = state.multiplexed[key] else { return nil }
                guard existing.isUsable else {
                    state.multiplexed[key] = nil
                    return nil
                }
                return existing
            }
            // Only ever an h2 connection: one that offered `h2` and was answered
            // `http/1.1` is parked in `idle` like any other h1 socket, because that
            // is what it is. So a miss here falls through to the ordinary path.
            if let shared {
                return Lease(connection: shared, idle: shared.markLeased())
            }
        }
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
        guard let leased else { return nil }
        _ = leased.nextIdleGeneration()
        return Lease(connection: leased, idle: leased.markLeased())
    }

    /// Park a connection whose exchange finished cleanly. Over a cap, or on a pool
    /// that has been drained, it is closed instead — a caller never has to ask.
    func release(_ connection: UpstreamConnection) {
        // An h2 connection is not *taken*, so it is not given back either: it stays
        // registered until it dies, idles out or is drained. Closing it here would
        // kill the streams other exchanges are still running on it.
        if connection.negotiated == .http2 {
            guard connection.isUsable else {
                forget(connection)
                return
            }
            state.withLock { $0.multiplexed[connection.key] = connection }
            return
        }
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
        scheduleIdleExpiry(connection, generation: generation)
    }

    /// Close a **parked h1** connection that has gone `idleTimeout` without being
    /// leased again.
    ///
    /// The generation check is what makes this cancellation-free: every lease and
    /// release bumps it, so a timer scheduled for an earlier idle period recognises
    /// itself as stale and a re-parked connection carries a fresh one.
    private func scheduleIdleExpiry(_ connection: UpstreamConnection, generation: Int) {
        connection.channel.eventLoop.scheduleTask(in: limits.idleTimeout) { [weak self] in
            guard let self, connection.isIdleGenerationCurrent(generation) else { return }
            expire(connection)
        }
    }

    /// Watch a **shared h2** connection for going quiet, re-arming until it does.
    ///
    /// It cannot use the h1 shape, and that difference is the whole bug this closes.
    /// A shared connection is never released back, so there is no moment at which to
    /// schedule "expire unless leased again" — and a generation check would either
    /// fire under live traffic or, once bumped, drop the watch forever. So the watch
    /// re-arms and asks the connection itself: idle means nothing has *started or
    /// finished* on it for the timeout **and** nothing is running now, which is what
    /// keeps a long-lived stream (SSE, a slow download) from being cut mid-response
    /// while nobody opens new streams.
    private func watchHTTP2Idle(_ connection: UpstreamConnection) {
        // Remaining time, not another full window: a re-arm that always waits
        // `idleTimeout` again lets a connection sit quiet for almost 2× the
        // timeout, past the 60–75 s origin reapers this limit is meant to beat.
        let delay = connection.remainingIdle(of: limits.idleTimeout) ?? limits.idleTimeout
        connection.channel.eventLoop.scheduleTask(in: delay) { [weak self] in
            guard let self else { return }
            guard connection.isUsable else {
                forget(connection)
                return
            }
            guard connection.isIdle(longerThan: limits.idleTimeout) else {
                watchHTTP2Idle(connection)
                return
            }
            expire(connection)
        }
    }

    /// Drop and close a connection the idle timer caught, counting it. An idle expiry
    /// is a **normal** outcome, not a failure: it is the pool declining to be the
    /// side that finds out a socket died.
    private func expire(_ connection: UpstreamConnection) {
        // Re-check under the connection lock: `beginExchange` / `markLeased` can
        // land between `isIdle` and here, and h2 has no generation to cancel the
        // watch. Winning the claim marks us closed so a concurrent lease misses.
        guard connection.claimIdleExpiry(after: limits.idleTimeout) else {
            if connection.negotiated == .http2, connection.isUsable {
                watchHTTP2Idle(connection)
            }
            return
        }
        stats.withLock { $0.idleExpiries += 1 }
        Log.forward.debug(
            """
            Closing the idle upstream connection to \(connection.key.host, privacy: .public):\
            \(connection.key.port, privacy: .public) \
            (\(connection.negotiated == .http2 ? "h2" : "h1", privacy: .public), \
            idle over \(self.limits.idleTimeout.nanoseconds / 1_000_000, privacy: .public) ms)
            """
        )
        forget(connection)
        connection.channel.close(promise: nil)
    }

    /// Register a freshly-connected h2 connection, and say which one to actually
    /// use. Called **before the first stream is opened on it**, which is what makes
    /// the losing side safe to close: two exchanges that both missed the pool and
    /// both connected have, at this moment, nothing running on either socket.
    ///
    /// Registering at connect time rather than at release is the difference between
    /// a race window as wide as one `connect()` and one as wide as a whole exchange
    /// — and, since a shared connection is never "released" in the h1 sense, the
    /// only point at which the duplicate can still be closed harmlessly.
    func registerMultiplexed(_ connection: UpstreamConnection) -> UpstreamConnection {
        let winner = state.withLock { state -> UpstreamConnection in
            if let incumbent = state.multiplexed[connection.key], incumbent.isUsable, incumbent !== connection {
                return incumbent
            }
            state.multiplexed[connection.key] = connection
            return connection
        }
        if winner !== connection {
            connection.close()
            return winner
        }
        // The idle watch starts here rather than at release, because a shared
        // connection is never released: registration is the only moment it is
        // certain to pass through exactly once.
        watchHTTP2Idle(connection)
        return winner
    }

    /// Drop a connection from the idle set without deciding whether to close it —
    /// called by the relay when a parked connection's socket goes away, where the
    /// close has already happened.
    func forget(_ connection: UpstreamConnection) {
        state.withLock { state in
            if state.multiplexed[connection.key] === connection { state.multiplexed[connection.key] = nil }
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
            for (key, connection) in state.multiplexed where key.identity == identityLabel {
                evicted.append(connection)
                state.multiplexed[key] = nil
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
            let all = state.idle.values.flatMap { $0 } + state.multiplexed.values
            state.idle = [:]
            state.totalIdle = 0
            state.multiplexed = [:]
            return all
        }
        for connection in parked { connection.close() }
    }

    /// Idle connections currently parked — for tests and for reasoning about a leak.
    var idleCount: Int { state.withLock { $0.totalIdle } }
}
