import NIOCore

/// Splices two channels together, relaying raw bytes in both directions.
/// Used for CONNECT tunnels so HTTPS passes through untouched in M1
/// (interception via MITM lands in a later milestone).
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
    }

    private func relayWrite(_ data: NIOAny) {
        context?.write(data, promise: nil)
    }

    private func relayFlush() {
        context?.flush()
    }

    private func relayClose() {
        context?.close(promise: nil)
    }
}
