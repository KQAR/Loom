import Foundation
import Synchronization
import NIOCore
import NIOPosix
import NIOHTTP1
import NIOHTTP2
import NIOTLS
import NIOHTTPCompression
import NIOSSL
import LoomSharedModels

/// Upstream client built directly on SwiftNIO (M4), replacing an earlier URLSession-based forwarder.
/// Unlike URLSession it lets Loom own every request header — notably `Host`, so a
/// map-remote rule can keep the original Host (`keepHostHeader`) — and originates
/// its own normally-validated TLS to the real server for the intercept path.
///
/// This is the foundation increment: it still returns a buffered `ForwardResult`
/// (whole body collected) and decompresses like the old path so captures stay
/// readable. True chunk-at-a-time streaming (SSE / large bodies), WebSocket, and
/// HTTP/2 build on this same NIO client in later increments.
// @unchecked Sendable with nothing to protect: every stored property is a `let`.
// The hatch exists because `EventLoopGroup` carries no Sendable conformance.
final class NIOStreamingForwarder: UpstreamForwarding, @unchecked Sendable {
    /// Largest decompressed:compressed ratio accepted from an upstream response.
    /// See the decompressor's installation below for why this isn't `.none`.
    static let maxDecompressionRatio = 100

    /// Whether an h2c client's exchange also gets an **h2c upstream leg**.
    ///
    /// **Off**, and off deliberately rather than unimplemented. It is built, it
    /// round-trips (a gRPC call with `grpc-status` trailers completes end to end
    /// against a real cleartext origin, and the `cookie` crumbs arrive split), and it
    /// then intermittently stalls under concurrent load: the request is captured, the
    /// origin answers, no write reports a failure, and the client waits forever. A
    /// hang with nothing on any surface is the one failure mode this proxy must not
    /// ship, so the leg stays HTTP/1.1 — against an h2-only origin that fails
    /// *visibly*, which is the honest half of a bad trade.
    ///
    /// Flipping this to `true` re-enables the leg and re-enables the two tests that
    /// pin it (`H2CPriorKnowledgeTests`). The reproduction, everything ruled out, and
    /// the one measurement that is still ambiguous: `docs/decisions/h2c-upstream-stall.md`.
    ///
    /// The **TLS** h2 leg is unaffected and on: it is verified against real origins.
    static let cleartextHTTP2Upstream = false

    private let group: EventLoopGroup
    private let connectTimeout: TimeAmount
    /// Mutual-TLS identities, consulted per upstream host. Nil = never present a
    /// client certificate (the default, and what an embedder gets unless it wires
    /// one — presenting a credential is not a neutral default).
    private let clientIdentities: ClientIdentityProviding?
    /// Keeps upstream connections alive between requests. See
    /// `UpstreamConnectionPool` for what a missing one used to cost.
    private let pool: UpstreamConnectionPool
    /// In-flight h2 connects, one per origin, so a burst that all misses the pool
    /// opens **one** socket rather than one each.
    ///
    /// The pool's own duplicate handling keeps the exchanges correct — they all end
    /// up on the winner — but correctness was never the cost here: measured, six
    /// concurrent first requests to one origin completed six TCP connects and six TLS
    /// handshakes to then use one connection and close five. That is the whole
    /// expense pooling exists to remove, reappearing on the protocol that needs a
    /// second connection least.
    private let pendingHTTP2Connects = Mutex<[UpstreamPoolKey: Task<UpstreamConnection, Error>]>([:])

    init(
        group: EventLoopGroup,
        connectTimeout: TimeAmount = .seconds(30),
        clientIdentities: ClientIdentityProviding? = nil,
        pool: UpstreamConnectionPool = UpstreamConnectionPool()
    ) {
        self.group = group
        self.connectTimeout = connectTimeout
        self.clientIdentities = clientIdentities
        self.pool = pool
    }

    func forward(method: String, url: URL, headers: [HeaderPair], body: Data?) async throws -> ForwardResult {
        try await forwardStream(method: method, url: url, headers: headers, body: .bytes(body)).collect()
    }

    func forwardStream(method: String, url: URL, headers: [HeaderPair], body: RequestBody) -> AsyncThrowingStream<UpstreamResponseEvent, Error> {
        forwardStream(method: method, url: url, headers: headers, body: body, origin: nil, clientProtocol: .http1)
    }

    func forwardStream(
        method: String, url: URL, headers: [HeaderPair], body: RequestBody,
        origin: RequestOrigin?, clientProtocol: ClientWireProtocol
    ) -> AsyncThrowingStream<UpstreamResponseEvent, Error> {
        AsyncThrowingStream { continuation in
            guard let host = url.host else {
                continuation.finish(throwing: ForwarderError.invalidURL(url.absoluteString))
                return
            }
            let isTLS = (url.scheme?.lowercased() == "https")
            let port = url.port ?? (isTLS ? 443 : 80)

            // Resolved before the attempt so it is available on the failure path too:
            // an mTLS handshake failure is the case where naming the identity (or its
            // absence) is the whole diagnosis. See `UpstreamTLSError`.
            let identity = isTLS ? self.clientIdentities?.identityLabel(forHost: host) : nil

            // The *context* is resolved here, before the attempt, and the handler is
            // built from it inside the channel initializer below. That split is not
            // cosmetic: resolving the context is the step that fails for a configured
            // identity that won't load, and that failure has to reach the caller
            // verbatim (naming the identity, not the origin — see the type note on
            // `resolveClientTLS`). `NIOSSLContext` is `Sendable`; `NIOSSLClientHandler`
            // is not, which is why only the latter moves inside.
            // Whether this exchange gets an h2 upstream leg. The client must have
            // spoken h2, and — for a TLS origin — the resolved context must actually
            // be offering `h2`, which is why that answer comes back from
            // `resolveClientTLS` rather than being assumed here. An exchange that
            // ends up on HTTP/1.1 says so on the flow: `CapturedResponse.httpVersion`
            // is Loom's upstream hop, so the leg is readable rather than guessed at.
            let clientTLS: (context: NIOSSLContext, serverName: String?, offersHTTP2: Bool)?
            do {
                clientTLS = try isTLS
                    ? self.resolveClientTLS(host: host, offerHTTP2: clientProtocol.isHTTP2)
                    : nil
            } catch {
                // A configured identity that won't load: the error already names it
                // (the store validates on the way in), so it is passed through as-is
                // rather than wrapped in a handshake story that never happened.
                continuation.finish(throwing: error)
                return
            }

            // Over TLS, ALPN asks and the origin may decline.
            //
            // **Cleartext h2c upstream is switched off** (`Self.cleartextHTTP2Upstream`)
            // — it works, and then intermittently stalls under load with no error
            // anywhere. An h2c client's exchange therefore goes upstream as HTTP/1.1,
            // which against an h2-only origin fails *visibly* (a parse error on the
            // flow) rather than hanging. See `docs/decisions/h2c-upstream-stall.md`.
            let wantsHTTP2 = isTLS
                ? (clientProtocol.isHTTP2 && (clientTLS?.offersHTTP2 ?? false))
                : (Self.cleartextHTTP2Upstream && clientProtocol == .http2Cleartext)
            let key = UpstreamPoolKey(
                host: host, port: port, isTLS: isTLS, identity: identity, preferHTTP2: wantsHTTP2
            )
            let active = ActiveUpstreamBox()
            let task = Task {
                do {
                    let trailers = try await self.runExchange(
                        key: key, clientTLS: clientTLS, method: method, url: url,
                        headers: headers, body: body, continuation: continuation, active: active
                    )
                    // The forwarder, not the relay, terminates the caller's stream:
                    // a failure with nothing yet yielded is a retry candidate, and a
                    // relay that had already finished the stream would have spent
                    // the outcome that decision needs. The trailer section rides this
                    // terminal event for the same reason — it is the last thing the
                    // origin said, and the relay never gets to say anything last.
                    continuation.yield(.end(trailers: trailers))
                    continuation.finish()
                } catch {
                    // Two wrappers, one hop each, and neither touches what the other
                    // claims: the TLS one only wraps NIOSSL's own errors, the
                    // connection one only wraps a failure to reach the address at all.
                    // Anything else — a mid-exchange close, an invalid URL — passes
                    // through both untouched.
                    let contextualized = UpstreamTLSError.wrapping(
                        error, host: host, isTLS: isTLS, identity: identity
                    )
                    continuation.finish(throwing: UpstreamConnectionError.wrapping(
                        contextualized, host: host, port: port
                    ))
                }
            }
            // On stream completion/cancellation, stop connecting and close the socket.
            continuation.onTermination = { _ in task.cancel(); active.terminate() }
        }
    }

    // MARK: - One exchange, over a pooled or a fresh connection

    /// Run one request/response, preferring a pooled connection.
    ///
    /// The retry is the load-bearing part of pooling and not a nicety: a parked
    /// connection can be closed by the origin at any moment, and the FIN can land
    /// in the window between leasing it and writing to it. Without a retry, pooling
    /// would trade a reliable 96 ms for an occasional failed request — a bad trade
    /// at any latency.
    ///
    /// It is offered only for a request whose body is `.bytes`, which is the whole
    /// reason `RequestBody` is a sum type here. A `.stream` body is a live,
    /// back-pressured pull from the client that is consumed exactly once; there is
    /// no second copy to re-send, so a streamed request opens its own connection
    /// rather than gamble one. It still *releases* into the pool afterwards, so the
    /// requests that follow it reuse the socket it opened.
    private func runExchange(
        key: UpstreamPoolKey,
        clientTLS: (context: NIOSSLContext, serverName: String?, offersHTTP2: Bool)?,
        method: String, url: URL, headers: [HeaderPair], body: RequestBody,
        continuation: AsyncThrowingStream<UpstreamResponseEvent, Error>.Continuation,
        active: ActiveUpstreamBox
    ) async throws -> [HeaderPair]? {
        let replayable: Bool
        if case .bytes = body.source { replayable = true } else { replayable = false }

        if replayable, let pooled = pool.lease(key) {
            do {
                return try await attempt(
                    on: pooled, reused: true, method: method, url: url, headers: headers, body: body,
                    continuation: continuation, active: active
                )
            } catch let failure as UpstreamAttemptFailure {
                guard !failure.didYield else { throw failure.underlying }
                // Bytes-in-hand makes the request *re-sendable*; it does not make
                // it *re-executable*. RFC 9110 §9.2.2 allows an automatic retry
                // for an idempotent method, or when there is a means to detect
                // that the original request was never applied.
                guard Self.mayRetry(method: method, after: failure) else {
                    throw failure.underlying
                }
                Log.forward.debug(
                    """
                    Pooled upstream connection to \(key.host, privacy: .public):\(key.port, privacy: .public) \
                    was stale; retrying on a fresh one
                    """
                )
            }
        }

        let fresh = key.preferHTTP2
            ? try await connectSharing(key: key, clientTLS: clientTLS)
            : try await connect(key: key, clientTLS: clientTLS)
        do {
            return try await attempt(
                on: fresh, reused: false, method: method, url: url, headers: headers, body: body,
                continuation: continuation, active: active
            )
        } catch let failure as UpstreamAttemptFailure {
            throw failure.underlying
        }
    }

    /// Arm the connection's slot, write the request, await the response's end, and
    /// then either park the connection or close it.
    private func attempt(
        on connection: UpstreamConnection,
        reused: Bool,
        method: String, url: URL, headers: [HeaderPair], body: RequestBody,
        continuation: AsyncThrowingStream<UpstreamResponseEvent, Error>.Continuation,
        active: ActiveUpstreamBox
    ) async throws -> [HeaderPair]? {
        if connection.negotiated == .http2 {
            return try await attemptHTTP2(
                on: connection, reused: reused, method: method, url: url, headers: headers,
                body: body, continuation: continuation, active: active
            )
        }
        guard active.adopt(closing: { connection.close() }) else {
            // The consumer already went away; nothing to run this exchange for.
            connection.close()
            throw CancellationError()
        }

        let promise = connection.channel.eventLoop.makePromise(of: UpstreamAttemptEnd.self)
        // Evaluated by the slot when the head arrives, not now: on a fresh
        // connection the handshake has not finished at arm time, so reading the
        // TLS box here would report nil for every first request on an origin.
        let remoteAddress = connection.remoteAddress
        let tlsBox = connection.tlsInfo
        // Setup costs go only to the exchange that opened the connection. A reuse
        // paid none of them, and charging it the original handshake would inflate
        // exactly the number someone is reading this to explain.
        let setup = reused ? nil : connection.setup
        connection.slot.arm(
            continuation: continuation,
            methodIsHead: method.uppercased() == "HEAD",
            transport: {
                var transport = FlowTransport(
                    remoteAddress: remoteAddress,
                    connectionReused: reused,
                    upstreamTLS: tlsBox.info
                )
                if var setup {
                    // Read at head time like the rest: the handshake finishes after
                    // `connect()` returns, so it is not known when the connection
                    // object is built.
                    setup.tlsHandshakeMS = tlsBox.handshakeMS
                    transport.setup = setup.isEmpty ? nil : setup
                }
                return transport
            }
        ) { result in
            promise.completeWith(result.mapError { $0 as Error })
        }

        // A TLS handshake failure does not come back from `connect()` — the TCP
        // connection succeeds and the handshake fails later, inside the pipeline —
        // so on a fresh connection it can land before the slot is armed. The slot
        // *holds* such a failure and `arm` above has already replayed it, with
        // NIOSSL's own error intact for `UpstreamTLSError` to name. This check is
        // the backstop for a channel that died before the slot ever heard why.
        if !connection.channel.isActive {
            connection.slot.fail(ForwarderError.connectionClosed)
        }

        // Whether the request's final flush succeeded — the fact the retry
        // decision (RFC 9110 §9.2.2) and the release decision below both need.
        var requestWritten = false
        let sendStartedAt = NIODeadline.now()
        do {
            try await Self.writeRequest(
                channel: connection.channel, method: method, url: url,
                host: connection.key.host, port: connection.key.port, headers: headers, body: body
            )
            requestWritten = true
            // **Not reported when this exchange waited for a handshake.** NIOSSL
            // buffers writes until the handshake completes, and the handshake runs
            // concurrently with this `attempt`, so on a fresh TLS connection the
            // clock above measures the handshake and not the send. Measured, not
            // reasoned: against a real origin it came back as 702 ms, digit for
            // digit the same number as `tlsHandshakeMS`, which is a wrong answer
            // dressed as a precise one. A reused connection has no handshake left
            // to wait for, and a fresh plaintext one was already writable when
            // `connect()` returned.
            let waitedForHandshake = !reused && connection.tlsInfo.handshakeMS != nil
            if !waitedForHandshake {
                let measured = UpstreamTLSObserver.milliseconds(since: sendStartedAt)
                // Its own instalment, yielded straight to the consumer: the
                // head-time closure was captured before the write and cannot see
                // this. Order against the other instalments does not matter — they
                // are *merged*, and nothing else sets this field.
                continuation.yield(.transport(FlowTransport(requestSendMS: measured)))
            }
        } catch {
            // Disarms and completes the promise; a no-op if the relay already saw
            // the failure first, which is the ordinary race on a dead socket.
            connection.slot.fail(error)
        }

        let end: UpstreamAttemptEnd
        do {
            end = try await promise.futureResult.get()
        } catch let failure as UpstreamAttemptFailure {
            active.clear()
            connection.close()
            // Re-stamp with the measured write outcome: the slot fills this field
            // conservatively because it never sees the write side.
            throw UpstreamAttemptFailure(
                underlying: failure.underlying, didYield: failure.didYield,
                requestWritten: requestWritten
            )
        } catch {
            active.clear()
            connection.close()
            throw error
        }

        active.clear()
        switch end.disposition {
        case .reusable where requestWritten:
            pool.release(connection)
        case .reusable:
            // The response completed but this request's body never fully left —
            // a server that answered early (413, an auth refusal) while the
            // upload still had bytes owing. The response is fine to deliver; the
            // connection is mid-request from the origin's point of view, and a
            // next request written onto it would land inside the unfinished body.
            connection.close()
        case .mustClose:
            connection.close()
        }
        return end.trailers
    }

    /// One exchange over an HTTP/2 connection: a fresh stream, its own slot, its own
    /// response stack.
    ///
    /// Three things differ from the h1 path, and each is a property of multiplexing
    /// rather than a simplification:
    ///
    /// - **The slot is per stream, not per connection.** `UpstreamExchangeSlot` is
    ///   the handoff for *one* exchange; under h2 a connection carries several at
    ///   once, so a shared slot would deliver one stream's head to another's caller.
    /// - **The connection is never closed on the way out.** `UpstreamAttemptEnd`'s
    ///   disposition answers "can this socket carry another request", which is
    ///   always yes for h2 and — critically — closing it would abort every other
    ///   stream in flight. Cancellation closes the *stream*, for the same reason.
    /// - **A stream carries no connection setup unless it opened it.** Same rule as
    ///   h1 reuse, and it is what `reused` already says.
    ///
    /// The response stack is the h1 one, unchanged, because
    /// `HTTP2FramePayloadToHTTP1ClientCodec` hands the stream over as
    /// `HTTPClientResponsePart` — the same events `UpstreamResponseRelay` already
    /// reads. That is also what makes `writeRequest` work here untouched.
    private func attemptHTTP2(
        on connection: UpstreamConnection,
        reused: Bool,
        method: String, url: URL, headers: [HeaderPair], body: RequestBody,
        continuation: AsyncThrowingStream<UpstreamResponseEvent, Error>.Continuation,
        active: ActiveUpstreamBox
    ) async throws -> [HeaderPair]? {
        guard let multiplexer = connection.multiplexer else {
            throw ForwarderError.connectionClosed
        }
        let slot = UpstreamExchangeSlot()
        let notifier = UpstreamInactiveNotifier()
        let scheme: HTTP2FramePayloadToHTTP1ClientCodec.HTTPProtocol = connection.key.isTLS ? .https : .http
        let streamPromise = connection.channel.eventLoop.makePromise(of: Channel.self)
        multiplexer.createStreamChannel(promise: streamPromise) { stream in
            stream.eventLoop.makeCompletedFuture {
                let sync = stream.pipeline.syncOperations
                try sync.addHandler(HTTP2FramePayloadToHTTP1ClientCodec(httpProtocol: scheme))
                try sync.addHandler(UpstreamEncodedBodyCounter(slot: slot))
                try sync.addHandler(
                    NIOHTTPResponseDecompressor(limit: .ratio(Self.maxDecompressionRatio))
                )
                try sync.addHandler(
                    UpstreamResponseRelay(slot: slot, notifier: notifier, httpVersion: "HTTP/2")
                )
            }
        }
        let stream: Channel
        do {
            stream = try await streamPromise.futureResult.get()
        } catch {
            // A connection that cannot open a stream is dead or going away
            // (GOAWAY, a closed socket). Nothing was yielded, so this is a retry
            // candidate exactly like a stale pooled h1 connection.
            pool.forget(connection)
            throw UpstreamAttemptFailure(underlying: error, didYield: false, requestWritten: false)
        }
        guard active.adopt(closing: { stream.close(promise: nil) }) else {
            stream.close(promise: nil)
            throw CancellationError()
        }

        let promise = stream.eventLoop.makePromise(of: UpstreamAttemptEnd.self)
        let remoteAddress = connection.remoteAddress
        let tlsBox = connection.tlsInfo
        let setup = reused ? nil : connection.setup
        slot.arm(
            continuation: continuation,
            methodIsHead: method.uppercased() == "HEAD",
            transport: {
                var transport = FlowTransport(
                    remoteAddress: remoteAddress,
                    connectionReused: reused,
                    upstreamTLS: tlsBox.info
                )
                if var setup {
                    setup.tlsHandshakeMS = tlsBox.handshakeMS
                    transport.setup = setup.isEmpty ? nil : setup
                }
                return transport
            }
        ) { result in
            promise.completeWith(result.mapError { $0 as Error })
        }

        var requestWritten = false
        do {
            try await Self.writeRequest(
                channel: stream, method: method, url: url,
                host: connection.key.host, port: connection.key.port, headers: headers, body: body,
                wire: .http2
            )
            requestWritten = true
        } catch {
            slot.fail(error)
        }

        let end: UpstreamAttemptEnd
        do {
            end = try await promise.futureResult.get()
        } catch let failure as UpstreamAttemptFailure {
            active.clear()
            stream.close(promise: nil)
            throw UpstreamAttemptFailure(
                underlying: failure.underlying, didYield: failure.didYield,
                requestWritten: requestWritten
            )
        } catch {
            active.clear()
            stream.close(promise: nil)
            throw error
        }
        active.clear()
        // The stream is finished; the connection carries on serving everyone else.
        stream.close(promise: nil)
        return end.trailers
    }

    /// Connect for an h2 origin, joining an attempt already under way rather than
    /// racing it.
    ///
    /// `Task.detached` on purpose: the connect is *shared*, so it must not inherit
    /// the cancellation of whichever exchange happened to start it — a client that
    /// walks away mid-handshake would otherwise take down the connection every other
    /// waiter is about to use.
    ///
    /// A shared attempt that produces a connection which is already unusable (the
    /// origin hung up between the handshake and here) falls through to a private
    /// connect rather than failing: the joiner has done nothing wrong, and one wasted
    /// socket beats a spurious error.
    private func connectSharing(
        key: UpstreamPoolKey, clientTLS: (context: NIOSSLContext, serverName: String?, offersHTTP2: Bool)?
    ) async throws -> UpstreamConnection {
        let (attempt, isOwner) = pendingHTTP2Connects.withLock { pending -> (Task<UpstreamConnection, Error>, Bool) in
            if let existing = pending[key] { return (existing, false) }
            let started = Task.detached { [self] in try await connect(key: key, clientTLS: clientTLS) }
            pending[key] = started
            return (started, true)
        }
        func forgetIfOwner() {
            guard isOwner else { return }
            pendingHTTP2Connects.withLock { pending in
                if pending[key] == attempt { pending[key] = nil }
            }
        }
        do {
            let connection = try await attempt.value
            forgetIfOwner()
            if connection.isUsable { return connection }
        } catch {
            forgetIfOwner()
            throw error
        }
        return try await connect(key: key, clientTLS: clientTLS)
    }

    /// Open a new upstream connection with the response relay already installed.
    private func connect(
        key: UpstreamPoolKey, clientTLS: (context: NIOSSLContext, serverName: String?, offersHTTP2: Bool)?
    ) async throws -> UpstreamConnection {
        let slot = UpstreamExchangeSlot()
        let notifier = UpstreamInactiveNotifier()
        let tlsInfo = UpstreamTLSInfoBox()
        let identity = key.identity
        // Settled by ALPN (TLS) or by prior knowledge (cleartext h2c). Held in a box
        // rather than returned from the initializer because the initializer runs
        // before the handshake, and for h2 the answer *is* the handshake's.
        let negotiation = UpstreamNegotiationBox()
        let bootstrap = ClientBootstrap(group: group)
            .connectTimeout(connectTimeout)
            .channelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .channelInitializer { channel in
                channel.eventLoop.makeCompletedFuture { () -> EventLoopFuture<Void> in
                    let sync = channel.pipeline.syncOperations
                    if let clientTLS {
                        try sync.addHandler(NIOSSLClientHandler(
                            context: clientTLS.context, serverHostname: clientTLS.serverName
                        ))
                        // Directly after the TLS handler, which is both where the
                        // completion event is raised and where NIOSSL's accessors
                        // look for it. Observation only — it does not verify.
                        try sync.addHandler(UpstreamTLSObserver(
                            box: tlsInfo, serverName: clientTLS.serverName, clientCertificate: identity
                        ))
                    }
                    guard key.preferHTTP2 else {
                        try Self.addHTTP1Handlers(sync: sync, slot: slot, notifier: notifier)
                        negotiation.settle(.http1, multiplexer: nil)
                        return channel.eventLoop.makeSucceededVoidFuture()
                    }
                    guard clientTLS?.offersHTTP2 == true else {
                        // Cleartext h2c with prior knowledge (RFC 9113 §3.4). Safe to
                        // commit to at all *only* because this path is reached solely
                        // for an exchange whose own client spoke h2c to this origin,
                        // so the origin is an h2c server by demonstration. There is no
                        // probe for it and no fallback from it.
                        //
                        // **It must go in here, in the initializer, before the channel
                        // is active** — moving it after `connect()` returns was tried
                        // and measured: the origin then never receives a single
                        // HEADERS frame (0 of 5 requests arrived, against a live
                        // origin answering a direct client 200). The likely reason is
                        // the connection preface, which `NIOHTTP2Handler` writes on
                        // activation; added to an already-active channel it is never
                        // sent, so the server cannot parse anything that follows.
                        // See ROADMAP § h2c upstream for what is still unexplained.
                        return Self.installUpstreamHTTP2(channel: channel, negotiation: negotiation)
                    }
                    // The origin decides. `http/1.1` is a legitimate answer to an
                    // `h2` offer and lands on the h1 stack, which is why both are
                    // installed from here rather than chosen before connecting.
                    try sync.addHandler(ApplicationProtocolNegotiationHandler { result in
                        if case .negotiated("h2") = result {
                            return Self.installUpstreamHTTP2(channel: channel, negotiation: negotiation)
                        }
                        return channel.eventLoop.makeCompletedFuture {
                            try Self.addHTTP1Handlers(
                                sync: channel.pipeline.syncOperations, slot: slot, notifier: notifier
                            )
                            negotiation.settle(.http1, multiplexer: nil)
                        }
                    })
                    return channel.eventLoop.makeSucceededVoidFuture()
                }.flatMap { $0 }
            }
        // DNS is timed by resolving here, *for measurement only* — the bootstrap
        // then resolves again and connects exactly as before.
        //
        // The obvious alternative is to hand the resolved address to
        // `connect(to:)` and skip the second lookup, and it is rejected on
        // purpose: `connect(host:port:)` runs NIO's Happy Eyeballs across the A
        // and AAAA answers, and replacing it with "the first address getaddrinfo
        // returned" changes how Loom behaves on every dual-stack network to make a
        // number prettier. The duplicate lookup is the *cheap* one — the first
        // resolve pays the real cost, which is what gets reported, and the
        // bootstrap's is served from the OS cache.
        //
        // A resolver failure here is not the connection's problem: it is swallowed,
        // `dnsMS` stays nil, and the bootstrap reports the real error a moment later.
        let dnsMS = await Self.measureResolution(host: key.host, port: key.port)
        let connectStartedAt = NIODeadline.now()
        let channel = try await bootstrap.connect(host: key.host, port: key.port).get()
        let setup = ConnectionSetup(
            dnsMS: dnsMS,
            tcpMS: UpstreamTLSObserver.milliseconds(since: connectStartedAt)
        )
        // For an h2 leg the protocol is not known when `connect()` returns — the TCP
        // connection is up and the handshake is not. Waiting here is what lets
        // `attempt` branch on a settled answer instead of guessing; a handshake that
        // fails resolves this as a failure through the channel's own close.
        let negotiated: UpstreamWireProtocol
        let multiplexer: HTTP2StreamMultiplexer?
        if key.preferHTTP2 {
            channel.closeFuture.whenComplete { _ in negotiation.failIfUnsettled(ForwarderError.connectionClosed) }
            let settled = try await negotiation.awaitSettled(on: channel.eventLoop)
            negotiated = settled.wire
            multiplexer = settled.multiplexer
        } else {
            negotiated = .http1
            multiplexer = nil
        }
        let connection = UpstreamConnection(
            key: key, channel: channel, slot: slot,
            negotiated: negotiated, multiplexer: multiplexer,
            tlsInfo: tlsInfo, setup: setup
        )
        // Weak: while the connection is parked the pool holds it, and once it is
        // neither parked nor in flight there is nothing left to evict.
        notifier.onInactive { [pool, weak connection] in
            guard let connection else { return }
            pool.forget(connection)
        }
        // An h2 connection is shared, so it is registered *before* a stream is
        // opened on it — see `UpstreamConnectionPool.registerMultiplexed` for why
        // that is the only moment a duplicate can still be closed harmlessly.
        if negotiated == .http2 {
            // The h2 connection's own death has to evict it too, and it has no
            // per-connection relay to notice: the relays live on stream channels.
            channel.closeFuture.whenComplete { [pool, weak connection] _ in
                guard let connection else { return }
                pool.forget(connection)
            }
            return pool.registerMultiplexed(connection)
        }
        return connection
    }

    /// The HTTP/1.1 response stack: framing, the encoded-size counter, the
    /// decompressor, the relay. One definition, because the ALPN branch installs it
    /// too — an origin answering `http/1.1` to an `h2` offer must get exactly the
    /// pipeline it would have got without the offer.
    private static func addHTTP1Handlers(
        sync: ChannelPipeline.SynchronousOperations,
        slot: UpstreamExchangeSlot,
        notifier: UpstreamInactiveNotifier
    ) throws {
        try sync.addHTTPClientHandlers()
        // Between the framing and the decompressor: the last point at which the body
        // is both parsed into parts and still encoded, which is the only place its
        // wire size still exists.
        try sync.addHandler(UpstreamEncodedBodyCounter(slot: slot))
        // Decompress gzip/deflate so relayed/captured bytes are plaintext; the
        // now-wrong Content-Encoding/Length are stripped on `.head`. The ratio cap is
        // a decompression-bomb guard: bodies come from arbitrary origins, and `.none`
        // is the setting swift-nio-extras itself documents as leaving you open to
        // denial of service. 100x is far above real content (text gzips ~3-10x) and
        // far below a zip bomb (1000x+), so it costs nothing legitimate. The capture
        // is separately capped; this bounds the *inflation*.
        //
        // Safe to keep across a pooled connection's later requests: it builds a
        // decoder per response `.head` and drops it on `.end`.
        try sync.addHandler(NIOHTTPResponseDecompressor(limit: .ratio(maxDecompressionRatio)))
        try sync.addHandler(UpstreamResponseRelay(slot: slot, notifier: notifier))
    }

    /// The HTTP/2 connection channel: just the multiplexer. Everything that reads a
    /// response — the counter, the decompressor, the relay — lives on the *stream*
    /// channel instead (`openHTTP2Stream`), because under h2 those are per-exchange
    /// facts and a connection carries many exchanges at once.
    private static func installUpstreamHTTP2(
        channel: Channel, negotiation: UpstreamNegotiationBox
    ) -> EventLoopFuture<Void> {
        channel.configureHTTP2Pipeline(
            mode: .client,
            // Same rule as the server side (`MITMPipeline.maxHeaderListSize`): a
            // proxy must not be stricter than the peer it stands in front of, and
            // NIO's 16 KB default is stricter than any real origin's response.
            initialLocalSettings: [
                HTTP2Setting(parameter: .maxHeaderListSize, value: MITMPipeline.maxHeaderListSize),
            ],
            // Server push. Loom never asks for it and never relays it, and an
            // unclaimed pushed stream that is merely ignored keeps a stream id and a
            // flow-control window open for the life of the connection — so it is
            // refused explicitly rather than left to accumulate.
            inboundStreamInitializer: { stream in stream.close() }
        ).map { multiplexer in
            negotiation.settle(.http2, multiplexer: multiplexer)
        }
    }

    /// Time one name resolution, off the event loop.
    ///
    /// `SocketAddress.makeAddressResolvingHost` is a synchronous `getaddrinfo`, so
    /// it gets `@concurrent` rather than being run inline — a blocking syscall on a
    /// cooperative-pool thread is the defect `ProcessResolver` documents.
    ///
    /// Nil for an IP literal (nothing to resolve, and reporting 0 ms would suggest
    /// a lookup happened) and nil for a failure.
    @concurrent private static func measureResolution(host: String, port: Int) async -> Int? {
        guard !SharedTLS.isIPLiteral(host) else { return nil }
        let startedAt = NIODeadline.now()
        guard (try? SocketAddress.makeAddressResolvingHost(host, port: port)) != nil else { return nil }
        return UpstreamTLSObserver.milliseconds(since: startedAt)
    }

    // MARK: - Request

    /// - Parameter wire: which leg this request is being framed for. The message is
    ///   the same either way; the *framing* is not, and both differences below are
    ///   things HTTP/2 forbids or wastes rather than preferences.
    private static func writeRequest(
        channel: Channel, method: String, url: URL, host: String, port: Int,
        headers: [HeaderPair], body: RequestBody, wire: UpstreamWireProtocol = .http1
    ) async throws {
        var httpHeaders = HTTPHeaders()
        var sawHost = false
        for header in headers {
            let lower = header.name.lowercased()
            // We set the framing (Content-Length / Transfer-Encoding) ourselves; drop
            // hop-by-hop and any framing the client stack must own. Host is kept if
            // present (so keepHostHeader works).
            if HTTPUtil.isHopByHop(lower) || lower == "content-length" || lower == "transfer-encoding" { continue }
            if lower == "host" { sawHost = true }
            httpHeaders.add(name: header.name, value: header.value)
        }
        if !sawHost {
            let defaultPort = url.scheme?.lowercased() == "https" ? 443 : 80
            httpHeaders.add(name: "Host", value: port == defaultPort ? host : "\(host):\(port)")
        }

        // Pin Accept-Encoding to what the response pipeline can actually inflate.
        // NIOHTTPResponseDecompressor only handles gzip/deflate, but the client's
        // own list (every browser advertises `br`, Chrome also `zstd`) would be
        // forwarded verbatim — the origin then responds with an encoding we pass
        // through still-compressed while sanitizeDecodedResponseHeaders strips the
        // Content-Encoding the client would need to decode it. Compressed bytes
        // typed as plaintext: broken for the client, unreadable in the capture.
        httpHeaders.replaceOrAdd(name: "Accept-Encoding", value: "gzip, deflate")

        // Frame the body: a known length (buffered body, or a streamed body whose
        // client sent Content-Length) uses Content-Length; an unknown-length stream
        // (client used chunked) re-frames as chunked upstream.
        // A trailer section is only legal on a chunked message (RFC 9112 §7.1.2), so
        // a body whose trailers are *already in hand* is re-framed chunked rather
        // than losing them to a `Content-Length`. That is the buffered path — a rule
        // that had to materialize the body, a breakpoint that held it — and it is
        // where an h2 client's perfectly legal `content-length` + trailers pair
        // would otherwise be silently halved.
        let knownLength: Int?
        switch body.source {
        case let .bytes(data):
            knownLength = body.trailers?.current == nil ? (data?.count ?? 0) : nil
        case let .stream(_, contentLength):
            knownLength = contentLength
        }
        if let knownLength {
            httpHeaders.replaceOrAdd(name: "Content-Length", value: String(knownLength))
        } else if wire == .http1 {
            httpHeaders.replaceOrAdd(name: "Transfer-Encoding", value: "chunked")
        }
        // …and nothing in the `else` for h2, deliberately. `Transfer-Encoding` is a
        // connection-specific field, which RFC 9113 §8.2.2 says a request MUST NOT
        // contain and a receiver MUST treat as malformed; h2 needs no framing header
        // anyway, since the body ends with END_STREAM.
        //
        // Belt-and-braces rather than load-bearing, and measured as such:
        // `HTTP2FramePayloadToHTTP1ClientCodec` strips connection-specific fields on
        // the way out, so removing this guard changes nothing observable today. It
        // stays because not emitting a field the protocol forbids is our job, not the
        // library's — and because the day that stripping changes, the failure would
        // be every unknown-length upload on an h2 leg becoming a stream error.

        if wire == .http2 {
            // One field per cookie-pair — the encoding §8.2.3 exists to permit. The
            // model's canonical single field (see `HTTPUtil.coalesceCookieCrumbs`) is
            // what the origin's application still sees; this is framing, and it is
            // what lets HPACK index the pairs instead of re-sending kilobytes of
            // cookie as a literal on every request.
            httpHeaders = HTTPUtil.splitCookieCrumbs(httpHeaders)
        }

        let head = HTTPRequestHead(
            version: .http1_1, method: httpMethod(method), uri: requestURI(url), headers: httpHeaders
        )
        // `promise: nil`, and **do not "fix" this by awaiting it**. A `write` without
        // a flush completes only when the flush happens, and the flush is the `.end`
        // below — so awaiting here waits for something this function has not done
        // yet. Measured: it deadlocks every request, which is a far worse failure
        // than the swallowed encode error awaiting was meant to surface. The failure
        // does still reach the exchange: NIO fails the subsequent writes on the same
        // channel, and the awaited `.end` flush is where that lands.
        channel.write(HTTPClientRequestPart.head(head), promise: nil)

        switch body.source {
        case let .bytes(data):
            if let data, !data.isEmpty {
                var buffer = channel.allocator.buffer(capacity: data.count)
                buffer.writeBytes(data)
                channel.write(HTTPClientRequestPart.body(.byteBuffer(buffer)), promise: nil)
            }
        case let .stream(chunks, _):
            // Await each flush so a slow upstream back-pressures the pull from the
            // client stream (which is itself back-pressured to the client socket) —
            // in-flight bytes stay bounded end to end.
            for try await chunk in chunks where !chunk.isEmpty {
                var buffer = channel.allocator.buffer(capacity: chunk.count)
                buffer.writeBytes(chunk)
                try await channel.writeAndFlush(HTTPClientRequestPart.body(.byteBuffer(buffer))).get()
            }
        }
        // Read *after* the body has been drained, which is the only point at which a
        // streamed request's trailer section exists (see `RequestTrailers`).
        //
        // One case survives the re-framing above and is dropped: a **streamed** body
        // whose client declared a `Content-Length` and then sent trailers anyway —
        // legal over h2, impossible over h1. The framing was chosen before the first
        // chunk went out and cannot be taken back. The capture records them either
        // way, so this is a visible drop rather than a silent one.
        let requestTrailers = knownLength == nil ? body.trailers?.current : nil
        // Awaited, unlike the parts above: on a pooled connection the origin may
        // have closed while it was parked, and this flush is where that surfaces.
        // With `promise: nil` the failure was swallowed and the exchange waited on
        // a response the socket could never carry.
        try await channel.writeAndFlush(
            HTTPClientRequestPart.end(requestTrailers.map(HTTPUtil.httpHeaders))
        ).get()
    }

    /// Origin-form request target: path + query (path defaults to "/").
    private static func requestURI(_ url: URL) -> String {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url.path.isEmpty ? "/" : url.path
        }
        let path = components.percentEncodedPath.isEmpty ? "/" : components.percentEncodedPath
        if let query = components.percentEncodedQuery { return "\(path)?\(query)" }
        return path
    }

    /// RFC 9110 §9.2.2's idempotent set. PUT and DELETE are in it by definition —
    /// repeating them re-asserts the same state — and POST/PATCH are out, which is
    /// the half that matters: those are the requests a retry can execute twice.
    static func isIdempotent(_ method: String) -> Bool {
        switch method.uppercased() {
        case "GET", "HEAD", "PUT", "DELETE", "OPTIONS", "TRACE": return true
        default: return false
        }
    }

    /// Whether a **pooled** attempt that yielded nothing may be re-run on a fresh
    /// connection.
    ///
    /// ## What was wrong before, and why it wasn't strictness
    ///
    /// The rule used to be `isIdempotent(method) || !failure.requestWritten`, on the
    /// reading that a successful final flush proves the origin read a complete
    /// request. **It proves no such thing.** A write to a socket whose peer has
    /// already closed succeeds locally — it lands in this host's send buffer, and
    /// FIN only ends the peer→us direction — and the RST comes back afterwards, on
    /// the read. So the common case of an origin reaping an idle keep-alive
    /// connection produces `requestWritten == true` for a request no origin ever
    /// saw, and a POST on that connection failed while the identical POST on a fresh
    /// one succeeded. That is the classic idle-connection race every HTTP client has
    /// to answer, and Loom answered it with a flag that cannot carry the meaning it
    /// was being read for.
    ///
    /// ## The evidence that does hold
    ///
    /// This is only ever asked on the pooled branch, with nothing yielded — so the
    /// connection was **parked idle before this exchange** and died before one byte
    /// of reply. What remains is *what killed it*, and that is the discriminator:
    ///
    /// - **Transport teardown** (`ForwarderError.connectionClosed`, `IOError` —
    ///   ECONNRESET/EPIPE — `ChannelError`, `NIOSSLError`) is the reaped-socket
    ///   shape. A peer that had already fully closed has no socket left to deliver
    ///   to, so the kernel answers the write with RST and the bytes reach no
    ///   application. RFC 9110 §9.2.2's "means to detect that the original request
    ///   was never applied" is exactly this, and it is what every mainstream client
    ///   retries on.
    /// - **Anything else** — a protocol error, a decoder failure, a timeout — is not
    ///   retried for a non-idempotent method. Those can follow an origin having read
    ///   and acted on the request, and running a POST twice stays the caller's
    ///   decision.
    ///
    /// The residual risk is stated rather than hidden: an origin *could* read a
    /// request, act on it, and reset without sending a byte. Loom cannot distinguish
    /// that from a reap, and the alternative — the old rule — failed every reaped
    /// POST to avoid it. A fresh connection keeps the strict rule, because there a
    /// failure after a successful write genuinely may mean the origin acted.
    static func mayRetry(method: String, after failure: UpstreamAttemptFailure) -> Bool {
        if isIdempotent(method) { return true }
        if !failure.requestWritten { return true }
        return isTransportTeardown(failure.underlying)
    }

    /// The connection died under the request, as opposed to answering it badly.
    ///
    /// Same tiering as `HTTP2ConnectionErrorReporter.classify`, and deliberately the
    /// same set of types: "the transport underneath is gone" is one question, and two
    /// answers to it in one module is how they come to disagree.
    static func isTransportTeardown(_ error: Error) -> Bool {
        if case ForwarderError.connectionClosed = error { return true }
        return error is IOError || error is ChannelError || error is NIOSSLError
    }

    private static func httpMethod(_ raw: String) -> HTTPMethod {
        switch raw.uppercased() {
        case "GET": return .GET
        case "POST": return .POST
        case "PUT": return .PUT
        case "DELETE": return .DELETE
        case "PATCH": return .PATCH
        case "HEAD": return .HEAD
        case "OPTIONS": return .OPTIONS
        case "TRACE": return .TRACE
        case "CONNECT": return .CONNECT
        default: return .RAW(value: raw.uppercased())
        }
    }

    /// The upstream TLS handler for `host`: normally the one shared, trust-store-only
    /// context, but a context carrying a client certificate when an mTLS identity is
    /// configured for this host. A configured-but-unloadable identity **throws**
    /// rather than falling back to the shared context: silently connecting without
    /// the credential would fail the handshake anyway, and the error would name the
    /// origin instead of the identity the operator can fix.
    /// The two `Sendable` ingredients an upstream TLS handler is built from, resolved
    /// **before** the connection attempt.
    ///
    /// Everything that can fail for a *configuration* reason fails here: a configured
    /// identity whose bundle won't load throws out of `context(forHost:)`, and the
    /// caller passes that error through untouched, because it already names the
    /// identity — which is the thing an operator can fix. Building the handler is left
    /// to the channel initializer, where the connection actually happens.
    private func resolveClientTLS(
        host: String, offerHTTP2: Bool
    ) throws -> (context: NIOSSLContext, serverName: String?, offersHTTP2: Bool) {
        // IP-literal peers can't take an SNI/validation hostname.
        let serverName = SharedTLS.isIPLiteral(host) ? nil : host
        // Identity for this host → its context; otherwise the provider's own
        // no-identity context (same trust settings, no client certificate), and only
        // then the process-wide default. The middle step keeps both paths on one
        // trust configuration; see `ClientIdentityProviding.baseContext()`.
        //
        // All three can offer `h2` — ALPN is fixed when a context is built, so the
        // provider caches one per (identity, ALPN) rather than being told after the
        // fact. The answer still travels *with* the context rather than being
        // re-derived from `offerHTTP2`, because offering a protocol the caller then
        // cannot speak is the one outcome that hangs an exchange, and a single
        // source for that fact is what stops the two from drifting.
        if let identityContext = try clientIdentities?.context(forHost: host, offeringHTTP2: offerHTTP2) {
            return (identityContext, serverName, offerHTTP2)
        }
        if let base = try clientIdentities?.baseContext(offeringHTTP2: offerHTTP2) {
            return (base, serverName, offerHTTP2)
        }
        return (
            offerHTTP2 ? SharedTLS.clientContextOfferingHTTP2 : SharedTLS.clientContext,
            serverName,
            offerHTTP2
        )
    }
}

enum ForwarderError: Error {
    case invalidURL(String)
    case connectionClosed
}

/// Carries the upstream protocol out of the channel initializer, where it is decided,
/// to `connect()`, which is waiting for it.
///
/// It has to be a box rather than a return value because the initializer runs before
/// the TLS handshake and the answer *is* the handshake's — and it has to be settled
/// exactly once from either side, since a handshake that fails settles it by closing
/// the channel while the ALPN handler never runs at all.
///
/// `@unchecked Sendable` for the same reason `UpstreamConnection` is: everything is
/// inside the `Mutex` except `HTTP2StreamMultiplexer`, which NIOHTTP2 does not
/// declare `Sendable` and which is only ever touched on its own channel's loop.
final class UpstreamNegotiationBox: @unchecked Sendable {
    /// `@unchecked Sendable`, escape-hatch kind 3 (ProxyCore/CLAUDE.md § Sendable
    /// escape hatches): both fields are `let`, and the hatch exists only because
    /// NIOHTTP2 does not declare `HTTP2StreamMultiplexer` `Sendable`. It is created
    /// on its channel's event loop and `createStreamChannel` is documented as safe
    /// to call from any thread — the same standing the `Channel` references in this
    /// module already have.
    struct Settled: @unchecked Sendable {
        let wire: UpstreamWireProtocol
        let multiplexer: HTTP2StreamMultiplexer?
    }

    private struct State {
        var settled: Settled?
        var failure: Error?
        var waiters: [EventLoopPromise<Void>] = []
    }

    private let state = Mutex(State())

    func settle(_ wire: UpstreamWireProtocol, multiplexer: HTTP2StreamMultiplexer?) {
        let waiters = state.withLock { state -> [EventLoopPromise<Void>] in
            guard state.settled == nil, state.failure == nil else { return [] }
            state.settled = Settled(wire: wire, multiplexer: multiplexer)
            let waiting = state.waiters
            state.waiters = []
            return waiting
        }
        // Outside the lock: completing a promise runs a stranger's continuation, and
        // that must never happen inside this critical section (ProxyCore/CLAUDE.md
        // § Sendable escape hatches).
        for waiter in waiters { waiter.succeed(()) }
    }

    /// Settle as a failure, unless an answer already arrived. Called from the
    /// channel's `closeFuture`, which fires on *every* close — including the ordinary
    /// one long after a successful negotiation, hence "if unsettled".
    func failIfUnsettled(_ error: Error) {
        let waiters = state.withLock { state -> [EventLoopPromise<Void>] in
            guard state.settled == nil, state.failure == nil else { return [] }
            state.failure = error
            let waiting = state.waiters
            state.waiters = []
            return waiting
        }
        for waiter in waiters { waiter.fail(error) }
    }

    func awaitSettled(on eventLoop: EventLoop) async throws -> Settled {
        let promise: EventLoopPromise<Void>? = try state.withLock { state in
            if let failure = state.failure { throw failure }
            if state.settled != nil { return nil }
            let waiter = eventLoop.makePromise(of: Void.self)
            state.waiters.append(waiter)
            return waiter
        }
        if let promise { try await promise.futureResult.get() }
        return try state.withLock { state in
            if let settled = state.settled { return settled }
            throw state.failure ?? ForwarderError.connectionClosed
        }
    }
}

/// Tracks the connection an in-flight exchange is running on, so the stream's
/// `onTermination` can close it when the consumer walks away mid-response — and,
/// just as importantly, so it does **not** close one that has already been handed
/// back to the pool.
private final class ActiveUpstreamBox: Sendable {
    private struct State {
        var closer: (@Sendable () -> Void)?
        var terminated = false
    }

    private let state = Mutex(State())

    /// Take ownership of whatever this exchange is running on, for its duration.
    /// Returns false if the consumer already terminated, in which case there is
    /// nothing left to run and the caller closes it.
    ///
    /// A closure rather than an `UpstreamConnection`, because under HTTP/2 the thing
    /// to close when the consumer walks away is the **stream**, not the connection —
    /// closing the latter would abort every other exchange sharing it.
    func adopt(closing closer: @escaping @Sendable () -> Void) -> Bool {
        state.withLock { state in
            guard !state.terminated else { return false }
            state.closer = closer
            return true
        }
    }

    /// The exchange finished; whatever happens now is the pool's decision, not this
    /// box's.
    func clear() {
        state.withLock { $0.closer = nil }
    }

    func terminate() {
        let closer = state.withLock { state -> (@Sendable () -> Void)? in
            state.terminated = true
            let current = state.closer
            state.closer = nil
            return current
        }
        closer?()
    }
}

/// Relays one HTTP response upstream→stream as it arrives: `.head` then each body
/// chunk, so SSE / long-poll / large downloads flow through instead of being
/// buffered.
///
/// Two things it deliberately does **not** do, both of which it used to. It does not
/// close the channel on `.end` — that is what made every request pay a fresh TCP
/// and TLS handshake, and the decision now belongs to the pool. And it does not
/// terminate the caller's stream: it hands the outcome to `UpstreamExchangeSlot`
/// and the forwarder decides, because a failure with nothing yielded is retryable
/// and finishing the stream here would spend that choice.
///
/// Plainly `Sendable`, not `@unchecked`: it holds no mutable state at all. What
/// would have been per-exchange handler state lives in the slot, which is exactly
/// what lets one relay serve many exchanges on a pooled connection.
private final class UpstreamResponseRelay: ChannelInboundHandler, Sendable {
    typealias InboundIn = HTTPClientResponsePart

    private let slot: UpstreamExchangeSlot
    private let notifier: UpstreamInactiveNotifier
    /// What Loom's upstream hop actually spoke, when the head cannot say.
    ///
    /// On an h2 stream `HTTP2FramePayloadToHTTP1ClientCodec` synthesizes an
    /// **HTTP/1.1** head — it is converting, not reporting — so deriving the version
    /// there records the shape of the conversion and not the connection. Exactly the
    /// mistake `CapturedRequest.httpVersion` documents on the client side, one leg
    /// over: it is *stated* by whoever installed the stack, never read off the head.
    private let httpVersionOverride: String?

    init(slot: UpstreamExchangeSlot, notifier: UpstreamInactiveNotifier, httpVersion: String? = nil) {
        self.slot = slot
        self.notifier = notifier
        self.httpVersionOverride = httpVersion
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case let .head(head):
            // Body is decompressed by the decompressor, so Content-Encoding/Length
            // no longer describe the bytes — strip them (the client writer re-frames).
            let headers = HTTPUtil.sanitizeDecodedResponseHeaders(HTTPUtil.headerPairs(head.headers))
            let version = httpVersionOverride ?? "HTTP/\(head.version.major).\(head.version.minor)"
            slot.receivedHead(head, headers: headers, httpVersion: version)
        case var .body(chunk):
            if let bytes = chunk.readBytes(length: chunk.readableBytes) {
                slot.receivedBody(Data(bytes))
            }
        case let .end(trailers):
            // `.end(nil)` is an ordinary response with no trailer section, and
            // `.end(headers)` is one that had one — the two must not collapse, or a
            // gRPC call's `grpc-status` disappears between the origin and the client.
            slot.completeSuccessfully(trailers: trailers.map(HTTPUtil.headerPairs))
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        // Fails an armed slot; a no-op when nothing is armed, which is what a
        // connection dying while parked in the pool looks like. Either way the pool
        // must stop offering it.
        slot.fail(ForwarderError.connectionClosed)
        notifier.fire()
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        slot.fail(error)
        context.close(promise: nil)
    }
}
