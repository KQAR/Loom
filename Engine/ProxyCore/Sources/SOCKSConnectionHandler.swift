import Foundation
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
                    Log.proxy.error("SOCKS handshake refused: \(String(describing: failure), privacy: .public)")
                    context.close(promise: nil)
                    phase = .done
                    return
                case let .value(greeting, consumed):
                    pending.removeFirst(consumed)
                    guard greeting.offersNoAuthentication else {
                        Log.proxy.error("SOCKS client offered no usable auth method; refusing")
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
                    Log.proxy.error("SOCKS request rejected: \(String(describing: failure), privacy: .public)")
                    write(SOCKS5.reply(replyCode(for: failure)), context: context, thenClose: true)
                    phase = .done
                    return
                case let .value(request, consumed):
                    pending.removeFirst(consumed)
                    guard request.command == .connect else {
                        // BIND / UDP ASSOCIATE. UDP is what a QUIC client wants, and a
                        // TCP proxy cannot carry it — say so instead of stalling.
                        Log.proxy.error("SOCKS \(String(describing: request.command), privacy: .public) not supported")
                        write(SOCKS5.reply(.commandNotSupported), context: context, thenClose: true)
                        phase = .done
                        return
                    }
                    target = request
                    write(SOCKS5.reply(.succeeded), context: context)
                    phase = .sniffing
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

    /// Install the stack the sniffed protocol calls for, then replay the bytes that
    /// paid for the decision.
    ///
    /// Reads are paused across the swap for the same reason the CONNECT path pauses
    /// them: the buffered prefix has to reach the new head of the pipeline *before*
    /// anything that arrives next, and this handler is gone by then.
    private func route(context: ChannelHandlerContext, guess: ClientProtocolGuess) {
        guard let target else { return }
        phase = .done
        let channel = context.channel
        let host = target.host
        let port = target.port
        var replay = channel.allocator.buffer(capacity: pending.count)
        replay.writeBytes(pending)
        pending = []

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
