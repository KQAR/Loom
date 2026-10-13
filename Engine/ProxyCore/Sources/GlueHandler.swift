import NIOCore

/// Splices two channels together, relaying raw bytes in both directions.
/// Used for CONNECT tunnels — with the whitelist SSL scope, every HTTPS origin nobody
/// named — and for the WebSocket splice, where `WebSocketTapHandler` observes the
/// same bytes on their way past.
///
/// Two properties of a relay, both of which this used to lack, and each measured:
///
/// - **Back-pressure.** It wrote everything it read into the partner and never asked
///   whether the partner could take it, so the gap between a fast origin and a slow
///   client queued in Loom: a 1 GB download through a tunnel to a client reading at
///   200 MB/s peaked at 1026 MB RSS. A read is now held while the partner is over its
///   write watermark and released when it drains (`channelWritabilityChanged`) — the
///   shape of SwiftNIO's own example glue handler.
/// - **A close that keeps what was already relayed.** It closed the partner the moment
///   its own side went inactive, which fails every write still queued there. An origin
///   that sends its last bytes and closes — an HTTP/1.0 body, a TLS `close_notify` —
///   lost the tail to any client slower than it: the same download arrived as 35 MB
///   of 1024, `transfer closed with 1037280708 bytes remaining`. The partner now
///   closes once its queued writes have flushed.
///
/// Both channels must share one event loop (`TunnelFlow.glue` pins them): a handler
/// reaches into its partner's context directly.
final class GlueHandler: ChannelDuplexHandler {
    typealias InboundIn = NIOAny
    typealias OutboundIn = NIOAny
    typealias OutboundOut = NIOAny

    /// `weak`, because `matchedPair()` points the two halves at each other and a strong
    /// pair is a retain cycle broken only by `handlerRemoved`. NIO does fire that on
    /// close, so nothing leaks today — but the lifetime doesn't need the strong edge at
    /// all: each handler is owned by its own channel's pipeline, so a partner that has
    /// gone away is exactly the nil `handlerRemoved` was already setting by hand. This
    /// removes the dependency on teardown running.
    private weak var partner: GlueHandler?
    private var context: ChannelHandlerContext?
    /// A read this side swallowed because the partner could not take more.
    private var pendingRead = false

    static func matchedPair() -> (GlueHandler, GlueHandler) {
        let first = GlueHandler()
        let second = GlueHandler()
        first.partner = second
        second.partner = first
        return (first, second)
    }

    func handlerAdded(context: ChannelHandlerContext) {
        self.context = context
    }

    func handlerRemoved(context: ChannelHandlerContext) {
        self.context = nil
        partner = nil
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        partner?.relayWrite(data)
    }

    func channelReadComplete(context: ChannelHandlerContext) {
        partner?.relayFlush()
    }

    func channelInactive(context: ChannelHandlerContext) {
        partner?.relayClose()
        context.fireChannelInactive()
    }

    func channelWritabilityChanged(context: ChannelHandlerContext) {
        if context.channel.isWritable { partner?.partnerBecameWritable() }
        context.fireChannelWritabilityChanged()
    }

    func read(context: ChannelHandlerContext) {
        if partner?.isWritable == true {
            context.read()
        } else {
            pendingRead = true
        }
    }

    private var isWritable: Bool { context?.channel.isWritable ?? false }

    private func partnerBecameWritable() {
        guard pendingRead, let context else { return }
        pendingRead = false
        context.read()
    }

    private func relayWrite(_ data: NIOAny) {
        context?.write(data, promise: nil)
    }

    private func relayFlush() {
        context?.flush()
    }

    /// Close once everything already relayed into this channel has been written. An
    /// empty write is ordered behind those, so its completion is theirs.
    private func relayClose() {
        guard let context else { return }
        let drained = context.channel.allocator.buffer(capacity: 0)
        context.writeAndFlush(NIOAny(drained)).assumeIsolated().whenComplete { _ in
            context.close(promise: nil)
        }
    }
}
