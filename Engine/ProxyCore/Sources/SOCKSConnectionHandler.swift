import Foundation
import LoomSharedModels
import NIOCore
import NIOPosix

/// Terminates one SOCKS5 client connection: performs the handshake, then decides
/// what the connection actually is and hands it to the same capture stack the
/// HTTP proxy port uses.
///
/// Why a second listener exists at all: the HTTP proxy port only ever sees traffic
/// from a client that speaks HTTP proxying (an absolute request URI or a
/// `CONNECT`). A large class of clients doesn't — Go/Rust/Node CLIs honouring only
/// `ALL_PROXY`, tools whose only proxy field is a SOCKS one, and anything that
/// isn't HTTP at all. Those are invisible to Loom today, which reads as "nothing
/// happened" rather than "nothing was routed here".
///
/// The order of operations is forced by the protocol: the client sends nothing
/// until it gets a success reply, so Loom must commit to the connection *before*
/// it can look at a single application byte. Hence the sniff (`ProtocolSniff`)
/// after the reply rather than a decision from the port number, and hence a raw
/// relay that only discovers an unreachable upstream after having already replied
/// success — the client sees the connection close, which is what mitmproxy's SOCKS
/// mode does too and is strictly better than refusing to capture anything.
///
/// No authentication is offered. That matches the HTTP proxy port, which is also
/// unauthenticated: both are bound to loopback unless the human explicitly turns
/// on LAN device capture, and that switch is the access-control decision.
// @unchecked Sendable: event-loop confined, no lock — see ProxyCore/CLAUDE.md
// § Sendable escape hatches for what that forbids inside a `Task {}`.
final class SOCKSConnectionHandler: ChannelInboundHandler, RemovableChannelHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    typealias InboundOut = ByteBuffer
    typealias OutboundOut = ByteBuffer

    private enum Phase {
        case greeting
        case request
        /// Handshake done, waiting for enough application bytes to classify.
        case sniffing
        /// Routed (or closing) — this handler no longer participates.
        case done
    }

    private let store: FlowStore
    private let group: EventLoopGroup
    private let forwarder: UpstreamForwarding
    private let ca: CertificateAuthority?
    private let config: InterceptionConfig
    private let observeTunnels: Bool

    private var phase: Phase = .greeting
    /// Bytes received and not yet consumed by the state machine. Bounded in
    /// practice: the handshake is a few hundred bytes at most, and the sniff phase
    /// routes at or before `ProtocolSniff.maxBytes`.
    private var pending: [UInt8] = []
    private var target: SOCKS5.Request?
    /// Fires if the client never speaks (see `armSniffDeadline`). Cancelled the moment
    /// routing happens, so a classified connection pays nothing for it.
    private var sniffDeadlineTask: Scheduled<Void>?

    init(
        store: FlowStore,
        group: EventLoopGroup,
        forwarder: UpstreamForwarding,
        ca: CertificateAuthority?,
        config: InterceptionConfig,
        observeTunnels: Bool = false
    ) {
        self.store = store
        self.group = group
        self.forwarder = forwarder
        self.ca = ca
        self.config = config
        self.observeTunnels = observeTunnels
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var buffer = unwrapInboundIn(data)
        guard phase != .done else {
            // Routed already; nothing should reach this handler, but forwarding is
            // the honest response to a byte we don't own.
            context.fireChannelRead(wrapInboundOut(buffer))
            return
        }
        if let bytes = buffer.readBytes(length: buffer.readableBytes) { pending.append(contentsOf: bytes) }
        advance(context: context)
    }

    /// A client that hangs up mid-handshake must not leave the sniff deadline armed:
    /// it would fire on a dead channel and open an upstream connection for an exchange
    /// nobody is waiting on.
    func channelInactive(context: ChannelHandlerContext) {
        phase = .done
        sniffDeadlineTask?.cancel()
        sniffDeadlineTask = nil
        context.fireChannelInactive()
    }

    /// Log a refusal both ways: to `os_log` for the human tailing the console, and
    /// to `RefusalLog` so `get_proxy_status` can answer an agent asking why nothing
    /// was captured. Only the first channel existed before, which made "the client
    /// never connected" and "Loom turned the client away" indistinguishable over
    /// MCP — the exact ambiguity the routing fields exist to remove.
    private func refuse(context: ChannelHandlerContext, reason: String) {
        Log.proxy.error("\(reason, privacy: .public)")
        RefusalLog.shared.record(ConnectionRefusal(
            listener: .socks,
            peer: context.channel.remoteAddress.map { String(describing: $0) },
            reason: reason
        ))
    }

    /// Turn a parse failure into something the operator can act on.
    ///
    /// `unsupportedVersion` is the one worth spelling out, and it can surface in
    /// either phase depending on how many bytes the client sent: an HTTP request
    /// aimed at the SOCKS port fails the greeting when it is short and the *request*
    /// when it is long enough for the greeting's length field to be satisfied by
    /// header bytes. Same mistake, same fix, so the guidance can't live in only one
    /// branch — which is exactly how the first version of this shipped.
    private static func reason(for failure: SOCKS5.Failure, phase: String) -> String {
        if case let .unsupportedVersion(byte) = failure {
            let printable = (32 ... 126).contains(byte) ? " ('\(Character(UnicodeScalar(byte)))')" : ""
            return """
            SOCKS \(phase) refused: first byte was 0x\(String(byte, radix: 16))\(printable), not SOCKS5. \
            That is what an HTTP proxy request or a SOCKS4 client looks like here — \
            point plain HTTP proxy clients at the HTTP proxy port instead.
            """
        }
        return "SOCKS \(phase) refused (\(failure))."
    }

    /// Drive the state machine as far as the buffered bytes allow.
    private func advance(context: ChannelHandlerContext) {
        while true {
            switch phase {
            case .greeting:
                switch SOCKS5.parseGreeting(pending) {
                case .needMore:
                    return
                case let .failure(failure):
                    // A SOCKS4 client lands here (version byte 0x04). Refusing is
                    // right — SOCKS4 has a different frame and no way to say "speak 5".
                    refuse(context: context, reason: Self.reason(for: failure, phase: "handshake"))
                    context.close(promise: nil)
                    phase = .done
                    return
                case let .value(greeting, consumed):
                    pending.removeFirst(consumed)
                    guard greeting.offersNoAuthentication else {
                        refuse(
                            context: context,
                            reason: "SOCKS client offered no authentication method Loom accepts (it requires \"no authentication\")."
                        )
                        write(SOCKS5.methodSelection(.unacceptable), context: context, thenClose: true)
                        phase = .done
                        return
                    }
                    write(SOCKS5.methodSelection(.noAuthentication), context: context)
                    phase = .request
                }

            case .request:
                switch SOCKS5.parseRequest(pending) {
                case .needMore:
                    return
                case let .failure(failure):
                    refuse(context: context, reason: Self.reason(for: failure, phase: "request"))
                    write(SOCKS5.reply(replyCode(for: failure)), context: context, thenClose: true)
                    phase = .done
                    return
                case let .value(request, consumed):
                    pending.removeFirst(consumed)
                    guard request.command == .connect else {
                        // BIND / UDP ASSOCIATE. UDP is what a QUIC client wants, and a
                        // TCP proxy cannot carry it — say so instead of stalling.
                        refuse(
                            context: context,
                            reason: """
                            SOCKS \(request.command) is not supported — Loom proxies TCP only. \
                            A UDP ASSOCIATE usually means the client wants QUIC, which no TCP \
                            proxy can carry.
                            """
                        )
                        write(SOCKS5.reply(.commandNotSupported), context: context, thenClose: true)
                        phase = .done
                        return
                    }
                    target = request
                    write(SOCKS5.reply(.succeeded), context: context)
                    phase = .sniffing
                    armSniffDeadline(context: context)
                }

            case .sniffing:
                let guess = ProtocolSniff.classify(pending)
                guard guess != .needMore else { return }
                route(context: context, guess: guess)
                return

            case .done:
                return
            }
        }
    }

    /// Route as opaque if the client hasn't said anything by the deadline.
    ///
    /// Sniffing the client's first bytes assumes the client speaks first. Plenty of
    /// protocols don't: SSH, SMTP, IMAP, MySQL and PostgreSQL all have the *server*
    /// send a banner or greeting before the client says a word — and those are a large
    /// part of why a SOCKS listener exists at all. Without this deadline such a
    /// connection deadlocks outright: the client waits for a banner, and Loom hasn't
    /// even opened the upstream connection because it is still waiting to classify.
    /// Found by pointing `nc -X 5` at a real SSH server; the integration test missed
    /// it because its opaque payload was client-first.
    ///
    /// The alternative was to connect upstream eagerly and let whichever side speaks
    /// first decide. That removes the delay but opens a connection Loom then throws
    /// away for every HTTP/TLS exchange — the common case — so the cost lands on the
    /// traffic Loom exists to capture rather than on the tail. A client that *does*
    /// speak first sends its bytes within microseconds of the reply (it is already
    /// waiting on the socket), so in practice only a server-first protocol ever pays
    /// this, once per connection, on a handshake that is not latency-critical.
    private func armSniffDeadline(context: ChannelHandlerContext) {
        let deadline = context.eventLoop.scheduleTask(in: Self.sniffDeadline) { [weak self] in
            guard let self, self.phase == .sniffing else { return }
            // Nothing buffered means nothing to classify; anything buffered that still
            // reads as `.needMore` is a partial prefix that isn't going to complete.
            self.route(context: context, guess: .opaque)
        }
        // Same event loop as every read, so no synchronisation is needed here.
        sniffDeadlineTask = deadline
    }

    /// How long to wait for a client to speak before assuming it never will.
    ///
    /// Short enough that a server-first handshake isn't visibly slowed, long enough
    /// that a client-first one is never misclassified — the latter is already sitting
    /// on the socket when the success reply goes out, so it wins this race by orders
    /// of magnitude, not by a margin.
    static let sniffDeadline: TimeAmount = .milliseconds(150)

    /// Install the stack the sniffed protocol calls for, then replay the bytes that
    /// paid for the decision.
    ///
    /// Reads are paused across the swap for the same reason the CONNECT path pauses
    /// them: the buffered prefix has to reach the new head of the pipeline *before*
    /// anything that arrives next, and this handler is gone by then.
    private func route(context: ChannelHandlerContext, guess: ClientProtocolGuess) {
        guard let target else { return }
        phase = .done
        sniffDeadlineTask?.cancel()
        sniffDeadlineTask = nil
        let channel = context.channel
        let host = target.host
        let port = target.port
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
            install = installTLS(channel: channel, host: host, port: port)
        case .http:
            install = MITMPipeline.installPlaintextHTTP(
                channel: channel, host: host, port: port, store: store, forwarder: forwarder
            )
        case .opaque, .needMore:
            install = relay(channel: channel, host: host, port: port)
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
                Log.proxy.error("SOCKS routing to \(host, privacy: .public):\(port) failed: \(String(describing: error))")
                channel.close(promise: nil)
            }
        }
    }

    /// MITM when the host is in the SSL-proxying scope and a CA exists; otherwise
    /// relay the ciphertext untouched — the same decision, and the same fail-open
    /// on a leaf that won't mint, as the CONNECT path.
    private func installTLS(channel: Channel, host: String, port: Int) -> EventLoopFuture<Void> {
        guard let ca, config.shouldIntercept(host: host) else {
            return relay(channel: channel, host: host, port: port)
        }
        do {
            let sslContext = try ca.serverContext(for: host)
            return MITMPipeline.installTLS(
                channel: channel, host: host, port: port, sslContext: sslContext,
                store: store, forwarder: forwarder
            )
        } catch {
            Log.tls.error("Leaf mint failed for \(host, privacy: .public) over SOCKS; relaying: \(String(describing: error))")
            return relay(channel: channel, host: host, port: port)
        }
    }

    /// Byte-transparent pass-through for traffic Loom won't read: out-of-scope TLS,
    /// h2c prior knowledge, and anything that isn't HTTP at all (SSH, SMTP, a
    /// hand-rolled binary protocol). Recorded as a tunnel flow when the embedder
    /// asked to observe tunnels, so the activity is visible even unread.
    private func relay(channel: Channel, host: String, port: Int) -> EventLoopFuture<Void> {
        let startedAt = Date()
        let store = self.store
        let observeTunnels = self.observeTunnels
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

    private func replyCode(for failure: SOCKS5.Failure) -> SOCKS5.Reply {
        switch failure {
        case .unsupportedCommand: return .commandNotSupported
        case .unsupportedAddressType, .malformedAddress: return .addressTypeNotSupported
        case .unsupportedVersion, .emptyMethodList: return .generalFailure
        }
    }

    private func write(_ bytes: [UInt8], context: ChannelHandlerContext, thenClose: Bool = false) {
        var buffer = context.channel.allocator.buffer(capacity: bytes.count)
        buffer.writeBytes(bytes)
        context.writeAndFlush(wrapOutboundOut(buffer)).whenComplete { _ in
            if thenClose { context.close(promise: nil) }
        }
    }
}
