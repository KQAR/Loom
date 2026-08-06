import Foundation
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

    /// How long to wait for a client to speak before assuming it never will.
    ///
    /// Short enough that a server-first handshake isn't visibly slowed, long enough
    /// that a client-first one is never misclassified — the latter is already sitting
    /// on the socket when the reply/ack goes out, so it wins this race by orders of
    /// magnitude, not by a margin. Server-first protocols (SSH, SMTP, IMAP, MySQL,
    /// PostgreSQL) are the reason it exists at all: classifying on client bytes alone
    /// deadlocks them, and only they ever pay it.
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
        context.fireChannelInactive()
    }

    func handlerRemoved(context: ChannelHandlerContext) {
        cancelDeadline()
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
            // Nothing buffered means nothing to classify; anything buffered that still
            // reads as `.needMore` is a partial prefix that isn't going to complete.
            self.route(context: context, guess: .opaque)
        }
    }

    private func cancelDeadline() {
        deadlineTask?.cancel()
        deadlineTask = nil
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
            install = relay(channel: channel)
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
        guard let ca, config.shouldIntercept(host: host) else {
            return relay(channel: channel)
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
            return relay(channel: channel)
        }
    }

    /// Byte-transparent pass-through for traffic Loom won't read: out-of-scope TLS,
    /// h2c prior knowledge, and anything that isn't HTTP at all (SSH, SMTP, a
    /// hand-rolled binary protocol). Recorded as a tunnel flow when the embedder
    /// asked to observe tunnels, so the activity is visible even unread.
    private func relay(channel: Channel) -> EventLoopFuture<Void> {
        let startedAt = Date()
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
                    TunnelFlow.record(host: host, port: port, startedAt: startedAt, store: store)
                }
                return TunnelFlow.glue(client: channel, upstream: upstream)
            }
    }
}
