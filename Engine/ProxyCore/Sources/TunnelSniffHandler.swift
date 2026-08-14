import Foundation
import LoomSharedModels
import NIOCore
import NIOPosix

/// Decides what an established tunnel is actually carrying — from its first bytes,
/// never from its port number — and installs the capture stack that fits.
///
/// Both entry points reach here, and for the same reason: each learns a *host and
/// port* before it can see a single application byte. SOCKS5 must send its success
/// reply first; the HTTP proxy must ack a `CONNECT` first. So neither can know
/// whether the tunnel will carry TLS, cleartext HTTP, or something Loom can't read.
///
/// Deciding from the port was the bug this replaces. `CONNECT` used to mean "TLS
/// follows" — true for `https://`, false for a browser's `ws://`, which Chrome and
/// Safari send as `CONNECT host:port` followed by a **plaintext** upgrade request.
/// With the host in the SSL scope Loom would ack, install a TLS terminator, and wait
/// for a ClientHello that never came: the handshake failed, the tunnel died, and the
/// WebSocket never reached the server. The same reasoning `ProtocolSniff` already
/// records for SOCKS applies verbatim to `CONNECT`, so this is one handler rather
/// than a second copy of the routing (see `MITMPipeline` on why two copies is how
/// one entry point rots).
// @unchecked Sendable: event-loop confined, no lock — see ProxyCore/CLAUDE.md
// § Sendable escape hatches for what that forbids inside a `Task {}`.
final class TunnelSniffHandler: ChannelInboundHandler, RemovableChannelHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    typealias InboundOut = ByteBuffer

    /// Which listener opened this tunnel. Only used to word a log line, but the
    /// wording is the difference between "the CONNECT path misrouted" and "the SOCKS
    /// path misrouted" when reading a failure after the fact.
    enum EntryPoint: String {
        case connect = "CONNECT"
        case socks = "SOCKS"
    }

    /// How long to wait for the client to speak before **asking the other side** —
    /// not before giving up on it.
    ///
    /// This used to be a classifier: on expiry the tunnel was declared `.opaque` and
    /// relayed byte-for-byte, unread. That was wrong twice over, and the proof is in
    /// `ProtocolSniff.classify`, which decides `.opaque` on the *first byte* for
    /// anything it doesn't recognise. So `.needMore` — the only state that survives
    /// to the deadline — means one of exactly two things, and the timer was a wrong
    /// answer to both:
    ///
    /// - **The client has said nothing.** Either it is a server-first protocol (SSH,
    ///   SMTP, IMAP, MySQL, PostgreSQL — the reason a deadline exists at all), or it
    ///   is a pooled connection a client opened *ahead of need*. OkHttp and Chrome
    ///   both do that: `CONNECT`, take the ack, park the tunnel, send the
    ///   ClientHello seconds later when a request finally wants it. Declaring those
    ///   opaque relayed every request on that connection unread — for the whole life
    ///   of the connection, silently, because an unread relay records no flow.
    /// - **The client has said part of something recognisable** (a lone `0x16`, a
    ///   prefix of the h2 preface, an unfinished method token). It is client-first by
    ///   demonstration; the rest of the prefix is merely late. On a lossy link a
    ///   split ClientHello is ordinary, and the old behaviour blind-relayed it —
    ///   losing capture exactly where a debugging proxy earns its keep.
    ///
    /// So expiry now starts a **speculative upstream connection** and lets whichever
    /// side speaks next settle it: a server greeting proves server-first (glue, reuse
    /// that connection), and client bytes classify normally (drop it, install the
    /// capture stack). Silence from both is not a verdict, and this handler no longer
    /// pretends it is — the tunnel simply stays undecided, which is what it is.
    ///
    /// The value stays 150 ms: it is what a server-first handshake waits before its
    /// greeting can arrive, and nothing else pays it.
    static let sniffDeadline: TimeAmount = .milliseconds(150)

    private let host: String
    private let port: Int
    private let store: FlowStore
    private let forwarder: UpstreamForwarding
    private let ca: CertificateAuthority?
    private let config: InterceptionConfig
    private let observeTunnels: Bool
    private let entryPoint: EntryPoint

    /// Bytes received and not yet routed. Bounded: routing happens at or before
    /// `ProtocolSniff.maxBytes`, or when the deadline fires.
    private var pending: [UInt8]
    /// Set the moment routing starts, so a late read or a fired deadline can't route
    /// a second time onto a pipeline this handler has already left.
    private var routed = false
    private var deadlineTask: Scheduled<Void>?
    /// The client channel, captured when this handler joins the pipeline so the
    /// probe's callback can reach it without carrying a non-`Sendable` `Channel`
    /// through a `@Sendable` bootstrap closure.
    private var clientChannel: Channel?
    /// The speculative upstream connection and its greeting buffer, live only
    /// between the deadline firing and whichever side speaks next.
    private var probe: Channel?
    private var probeHandler: UpstreamGreetingProbe?
    private var probeStarted = false

    init(
        host: String,
        port: Int,
        store: FlowStore,
        forwarder: UpstreamForwarding,
        ca: CertificateAuthority?,
        config: InterceptionConfig,
        observeTunnels: Bool,
        entryPoint: EntryPoint,
        initialBytes: [UInt8] = []
    ) {
        self.host = host
        self.port = port
        self.store = store
        self.forwarder = forwarder
        self.ca = ca
        self.config = config
        self.observeTunnels = observeTunnels
        self.entryPoint = entryPoint
        self.pending = initialBytes
    }

    /// Arm the deadline as soon as this handler is in the pipeline, and classify any
    /// bytes handed over with it.
    ///
    /// The initial bytes are classified from a queued task rather than inline: the
    /// caller's `addHandler` future hasn't completed yet, so routing here would
    /// reconfigure a pipeline mid-mutation. Auto-read is paused across the hand-over
    /// by both callers, so this task always runs before the next read.
    func handlerAdded(context: ChannelHandlerContext) {
        clientChannel = context.channel
        armDeadline(context: context)
        guard !pending.isEmpty else { return }
        // `assumeIsolated()` rather than a bare `execute`: the closure captures
        // `context`, which is not `Sendable`, and the plain overload takes a
        // `@Sendable` one. This turns the assumption the whole handler already rests on
        // — "everything here runs on this channel's loop" — into a checked precondition
        // instead of a comment. `handlerAdded` is called on the loop, so it holds.
        context.eventLoop.assumeIsolated().execute { [weak self] in
            guard let self, !self.routed else { return }
            self.advance(context: context)
        }
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var buffer = unwrapInboundIn(data)
        guard !routed else {
            // Routed already; nothing should reach this handler, but forwarding is
            // the honest response to a byte we don't own.
            context.fireChannelRead(wrapInboundOut(buffer))
            return
        }
        if let bytes = buffer.readBytes(length: buffer.readableBytes) { pending.append(contentsOf: bytes) }
        advance(context: context)
    }

    /// A client that hangs up before saying anything must not leave the deadline
    /// armed: it would fire on a dead channel and open an upstream connection for an
    /// exchange nobody is waiting on.
    func channelInactive(context: ChannelHandlerContext) {
        routed = true
        cancelDeadline()
        closeProbe()
        context.fireChannelInactive()
    }

    func handlerRemoved(context: ChannelHandlerContext) {
        cancelDeadline()
        // A probe still held here is one no route claimed — the server-first path
        // clears it first precisely so this doesn't close the connection it glued.
        closeProbe()
    }

    private func advance(context: ChannelHandlerContext) {
        guard !routed else { return }
        let guess = ProtocolSniff.classify(pending)
        guard guess != .needMore else { return }
        route(context: context, guess: guess)
    }

    private func armDeadline(context: ChannelHandlerContext) {
        // Same event loop as every read, so no synchronisation is needed here —
        // `assumeIsolated()` is what states that to the compiler (and checks it).
        deadlineTask = context.eventLoop.assumeIsolated().scheduleTask(in: Self.sniffDeadline) { [weak self] in
            guard let self, !self.routed else { return }
            self.startUpstreamProbe(context: context)
        }
    }

    private func cancelDeadline() {
        deadlineTask?.cancel()
        deadlineTask = nil
    }

    // MARK: - Asking the other side

    /// Open a speculative upstream connection and wait for whoever speaks next.
    ///
    /// It writes nothing: anything the client already said stays buffered here,
    /// because sending it would rule out the MITM this tunnel may still turn out to
    /// need. The connection exists only to hear a greeting.
    ///
    /// It is one connection per undecided tunnel, so it cannot outnumber the tunnels
    /// the client already opened — and it is dropped the moment the client speaks.
    /// A failure to connect is deliberately **not** a verdict either: the client may
    /// still be about to send a ClientHello, and the real connection made for it will
    /// fail on its own and be reported through `UpstreamConnectionError` rather than
    /// as a silently unread tunnel.
    private func startUpstreamProbe(context: ChannelHandlerContext) {
        guard !routed, !probeStarted else { return }
        probeStarted = true
        let host = self.host
        let port = self.port
        // Same loop as the client, so a glue built from this connection satisfies
        // `GlueHandler`'s one-loop requirement without a hop.
        let bootstrap = ClientBootstrap(group: context.eventLoop)
            .channelInitializer { [weak self] upstream in
                upstream.eventLoop.makeCompletedFuture {
                    let probe = UpstreamGreetingProbe(
                        onGreeting: { [weak self] in
                            // Fired on the upstream channel's loop, which is the client's.
                            self?.serverSpokeFirst()
                        },
                        onClosedSilent: { [weak self] in
                            self?.probeDied()
                        }
                    )
                    self?.probeHandler = probe
                    try upstream.pipeline.syncOperations.addHandler(probe)
                }
            }
        bootstrap.connect(host: host, port: port).assumeIsolated().whenComplete { [weak self] result in
            switch result {
            case let .success(upstream):
                guard let self, !self.routed else {
                    upstream.close(promise: nil)
                    return
                }
                self.probe = upstream
            case let .failure(error):
                // Not a verdict (see the note above) — but not silent either. In
                // the one corner where nothing else will ever report (a client
                // that never speaks against an origin that is down), this line is
                // the only trace the connection existed.
                Log.proxy.debug("""
                Speculative upstream probe to \(host, privacy: .public):\(port, privacy: .public) \
                failed: \(String(describing: error), privacy: .public). Not a verdict — the tunnel \
                stays undecided; the client's own connection will report if it ever speaks.
                """)
            }
        }
    }

    /// The probe's channel went away without ever greeting — an origin that
    /// accepted and then hung up, or an RST. Clear the dead reference so nothing
    /// later touches a closed channel; deliberately *not* a verdict and *not* a
    /// re-probe, for the same reason silence isn't: the client's own connection
    /// reports if it ever speaks.
    private func probeDied() {
        probe = nil
        probeHandler = nil
    }

    /// The upstream greeted us before the client said anything decisive: this is a
    /// server-first protocol, so glue the two ends and reuse the connection the
    /// greeting already arrived on.
    private func serverSpokeFirst() {
        guard !routed, let client = clientChannel, let upstream = probe, let probeHandler else { return }
        routed = true
        cancelDeadline()
        // Cleared *before* removing this handler: `handlerRemoved` closes a live
        // probe, and this is the one path where the probe is the connection we are
        // about to hand to the glue rather than one to discard.
        probe = nil
        self.probeHandler = nil

        let startedAt = Date()

        var clientSaid = client.allocator.buffer(capacity: pending.count)
        clientSaid.writeBytes(pending)
        pending = []
        let entryPoint = self.entryPoint
        let host = self.host
        let port = self.port

        // Both ends stay paused across the swap, for the same reason `route` pauses
        // the client: between removing a handler and installing the glue the
        // pipeline has nothing to receive bytes, and inbound bytes that reach the
        // end of a pipeline are dropped without a sound. The upstream side is the
        // one that matters here — it has already started talking.
        _ = client.setOption(ChannelOptions.autoRead, value: false)
        _ = upstream.setOption(ChannelOptions.autoRead, value: false)

        let observeTunnels = self.observeTunnels
        let store = self.store
        upstream.pipeline.removeHandler(probeHandler)
            .flatMap { client.pipeline.removeHandler(self) }
            .flatMap { TunnelFlow.glue(client: client, upstream: upstream, host: host, port: port) }
            .assumeIsolated()
            .whenComplete { result in
                guard case .success = result else {
                    Log.proxy.error("""
                    \(entryPoint.rawValue, privacy: .public) server-first splice to \
                    \(host, privacy: .public):\(port) failed: \(String(describing: result))
                    """)
                    client.close(promise: nil)
                    upstream.close(promise: nil)
                    return
                }
                // Recorded only once the splice actually stands: on the failure
                // path above both ends are closed, and listing the host as
                // "relayed" would claim activity the operator's client never got.
                TunneledHostLog.shared.record(host: host, port: port, reason: .notTLSOrHTTP)
                if observeTunnels {
                    TunnelFlow.record(
                        host: host, port: port, startedAt: startedAt, client: client, store: store
                    )
                }
                // Order matters: whatever the client managed to say before the
                // greeting has to reach the server ahead of anything it says next,
                // and the greeting itself was consumed by the probe, so nothing but
                // this write will ever deliver it.
                if clientSaid.readableBytes > 0 {
                    upstream.writeAndFlush(clientSaid, promise: nil)
                }
                if let greeting = probeHandler.takeBuffered(), greeting.readableBytes > 0 {
                    client.writeAndFlush(greeting, promise: nil)
                }
                _ = client.setOption(ChannelOptions.autoRead, value: true)
                _ = upstream.setOption(ChannelOptions.autoRead, value: true)
                client.read()
                upstream.read()
            }
    }

    /// Drop a speculative connection that turned out not to be the answer. Safe to
    /// call when there is none.
    private func closeProbe() {
        probe?.close(promise: nil)
        probe = nil
        probeHandler = nil
    }

    /// Install the stack the sniffed protocol calls for, then replay the bytes that
    /// paid for the decision.
    ///
    /// Reads stay paused across the swap: the buffered prefix has to reach the new
    /// head of the pipeline *before* anything that arrives next, and this handler is
    /// gone by then.
    private func route(context: ChannelHandlerContext, guess: ClientProtocolGuess) {
        routed = true
        cancelDeadline()
        // The client settled it, so a speculative connection opened while waiting is
        // the wrong one to keep: an `.opaque` route needs a fresh one it can glue,
        // and a MITM route must reach the origin through its own TLS. One wasted
        // connect, only on a tunnel that had already gone quiet past the deadline.
        closeProbe()

        let channel = context.channel
        let host = self.host
        let port = self.port
        let entryPoint = self.entryPoint
        var sniffed = channel.allocator.buffer(capacity: pending.count)
        sniffed.writeBytes(pending)
        pending = []
        // Frozen before the completion closure below captures it: a `var` would be a
        // shared mutable reference into this frame, and `ByteBuffer` is a value type,
        // so a copy is all the replay needs.
        let replay = sniffed

        _ = channel.setOption(ChannelOptions.autoRead, value: false)

        let install: EventLoopFuture<Void>
        switch guess {
        case .tls:
            install = installTLS(channel: channel)
        case .http:
            install = MITMPipeline.installPlaintextHTTP(
                channel: channel, host: host, port: port, store: store, forwarder: forwarder
            )
        case .opaque, .needMore:
            install = relay(channel: channel, reason: .notTLSOrHTTP)
        }

        channel.pipeline.removeHandler(self).flatMap { install }.whenComplete { result in
            switch result {
            case .success:
                if replay.readableBytes > 0 {
                    channel.pipeline.fireChannelRead(replay)
                    // The completion event matters as much as the bytes: a raw relay
                    // *writes* on read and *flushes* on readComplete, so replaying
                    // the sniffed prefix without it leaves those bytes sitting
                    // unflushed in the upstream channel — and since the client is
                    // waiting for a reply, nothing ever arrives to flush them.
                    channel.pipeline.fireChannelReadComplete()
                }
                _ = channel.setOption(ChannelOptions.autoRead, value: true)
                channel.read()
            case let .failure(error):
                Log.proxy.error("""
                \(entryPoint.rawValue, privacy: .public) routing to \
                \(host, privacy: .public):\(port) failed: \(String(describing: error))
                """)
                channel.close(promise: nil)
            }
        }
    }

    /// MITM when the host is in the SSL-proxying scope and a CA exists; otherwise
    /// relay the ciphertext untouched — with the same fail-open on a leaf that won't
    /// mint, because a site that stops loading is worse than a site Loom can't read.
    private func installTLS(channel: Channel) -> EventLoopFuture<Void> {
        if let reason = ProxyHandler.passthroughReason(host: host, config: config, ca: ca) {
            return relay(channel: channel, reason: reason)
        }
        guard let ca else {
            // Unreachable: `passthroughReason` returns `.noCertificateAuthority`
            // for a nil CA. Kept as a relay rather than a force-unwrap because
            // fail-open is this path's whole contract.
            return relay(channel: channel, reason: .noCertificateAuthority)
        }
        do {
            let sslContext = try ca.serverContext(for: host)
            return MITMPipeline.installTLS(
                channel: channel, host: host, port: port, sslContext: sslContext,
                store: store, forwarder: forwarder
            )
        } catch {
            Log.tls.error("""
            Leaf mint failed for \(self.host, privacy: .public) over \
            \(self.entryPoint.rawValue, privacy: .public); relaying: \(String(describing: error))
            """)
            return relay(channel: channel, reason: .leafMintFailed)
        }
    }

    /// Byte-transparent pass-through for traffic Loom won't read: out-of-scope TLS,
    /// h2c prior knowledge, and anything that isn't HTTP at all (SSH, SMTP, a
    /// hand-rolled binary protocol). Recorded as a tunnel flow when the embedder
    /// asked to observe tunnels, so the activity is visible even unread.
    ///
    /// `reason` is always recorded in `TunneledHostLog`, tunnel flows or not: it is
    /// the difference between a host one click away from capture and one no scope
    /// change can help.
    private func relay(channel: Channel, reason: TunnelReason) -> EventLoopFuture<Void> {
        let startedAt = Date()
        TunneledHostLog.shared.record(host: host, port: port, reason: reason)
        let store = self.store
        let observeTunnels = self.observeTunnels
        let host = self.host
        let port = self.port
        // Same event loop as the client: GlueHandler relays through its partner's
        // context, which NIO requires happen on that loop.
        return ClientBootstrap(group: channel.eventLoop)
            .connect(host: host, port: port)
            .flatMap { upstream in
                if observeTunnels {
                    TunnelFlow.record(
                        host: host, port: port, startedAt: startedAt, client: channel, store: store
                    )
                }
                return TunnelFlow.glue(client: channel, upstream: upstream, host: host, port: port)
            }
    }
}

/// Sits on a speculative upstream connection and reports the first byte the server
/// sends, which is the only evidence that separates a server-first protocol from a
/// tunnel whose client simply hasn't spoken yet.
///
/// It **buffers every byte** rather than only the first: the notification hands the
/// decision back to `TunnelSniffHandler`, and the pipeline reconfiguration that
/// follows takes several event-loop turns, during which more of the greeting can
/// arrive. Forwarding those on would drop them off the end of a pipeline that has
/// no glue in it yet — a server-first splice that loses the tail of its banner is a
/// hang, not a warning.
// @unchecked Sendable: event-loop confined, no lock — see ProxyCore/CLAUDE.md
// § Sendable escape hatches for what that forbids inside a `Task {}`.
final class UpstreamGreetingProbe: ChannelInboundHandler, RemovableChannelHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    typealias InboundOut = ByteBuffer

    private let onGreeting: @Sendable () -> Void
    /// The channel died having never greeted — the sniffer's reference to it is
    /// dead and must be dropped. Not fired after a greeting: from that point the
    /// connection belongs to the splice, whose own paths own its lifetime.
    private let onClosedSilent: @Sendable () -> Void
    private var buffered: ByteBuffer?
    private var announced = false

    init(onGreeting: @escaping @Sendable () -> Void, onClosedSilent: @escaping @Sendable () -> Void = {}) {
        self.onGreeting = onGreeting
        self.onClosedSilent = onClosedSilent
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var incoming = unwrapInboundIn(data)
        if buffered == nil {
            buffered = incoming
        } else {
            buffered?.writeBuffer(&incoming)
        }
        guard !announced else { return }
        announced = true
        onGreeting()
    }

    func channelInactive(context: ChannelHandlerContext) {
        if !announced { onClosedSilent() }
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        if !announced {
            onClosedSilent()
            context.close(promise: nil)
        }
        context.fireErrorCaught(error)
    }

    /// Hand over everything the server said. Called once, after this handler has
    /// been removed and the glue is in place.
    func takeBuffered() -> ByteBuffer? {
        defer { buffered = nil }
        return buffered
    }
}
