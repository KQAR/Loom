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
/// it can look at a single application byte. Hence the sniff after the reply rather
/// than a decision from the port number, and hence a raw relay that only discovers
/// an unreachable upstream after having already replied success — the client sees the
/// connection close, which is what mitmproxy's SOCKS mode does too and is strictly
/// better than refusing to capture anything.
///
/// This handler owns the handshake only. Everything after the success reply —
/// classification, the capture stack, the relay — belongs to `TunnelSniffHandler`,
/// which the `CONNECT` path also hands its tunnels to.
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
        /// Handshake done and handed to `TunnelSniffHandler` (or closing) — this
        /// handler no longer participates.
        case done
    }

    private let store: FlowStore
    private let group: EventLoopGroup
    private let forwarder: UpstreamForwarding
    private let ca: CertificateAuthority?
    private let config: InterceptionConfig
    private let observeTunnels: Bool

    private var phase: Phase = .greeting
    /// Bytes received and not yet consumed by the state machine. Bounded in practice:
    /// the handshake is a few hundred bytes at most, and anything left over when the
    /// handshake completes is handed to the sniffer rather than accumulated here.
    private var pending: [UInt8] = []

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

    func channelInactive(context: ChannelHandlerContext) {
        phase = .done
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
                    write(SOCKS5.reply(.succeeded), context: context)
                    phase = .done
                    handOff(context: context, request: request)
                    return
                }

            case .done:
                return
            }
        }
    }

    /// Hand the connection to `TunnelSniffHandler`, which classifies it and installs
    /// the matching stack — the same routing the CONNECT path uses, deliberately not
    /// a second copy of it.
    ///
    /// Removal comes first, then the add: reads are paused across the swap, so nothing
    /// arrives in between, and the sniffer then sees a pipeline with no leftover
    /// handshake handler ahead of it. Any application bytes that arrived pipelined
    /// with the request go along as `initialBytes` — dropping them would lose the very
    /// prefix the classification depends on.
    private func handOff(context: ChannelHandlerContext, request: SOCKS5.Request) {
        let channel = context.channel
        let sniffer = TunnelSniffHandler(
            host: request.host, port: request.port, store: store, forwarder: forwarder,
            ca: ca, config: config, observeTunnels: observeTunnels, entryPoint: .socks,
            initialBytes: pending
        )
        pending = []

        _ = channel.setOption(ChannelOptions.autoRead, value: false)
        channel.pipeline.removeHandler(self)
            .flatMap { channel.pipeline.addHandler(sniffer) }
            .whenComplete { result in
                switch result {
                case .success:
                    _ = channel.setOption(ChannelOptions.autoRead, value: true)
                    channel.read()
                case let .failure(error):
                    Log.proxy.error("""
                    SOCKS hand-off to \(request.host, privacy: .public):\(request.port) \
                    failed: \(String(describing: error))
                    """)
                    channel.close(promise: nil)
                }
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
