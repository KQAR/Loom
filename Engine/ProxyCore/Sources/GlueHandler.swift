import NIOCore

/// Splices two channels together, relaying raw bytes in both directions.
/// Used for CONNECT tunnels so HTTPS passes through untouched in M1
/// (interception via MITM lands in a later milestone).
final class GlueHandler: ChannelDuplexHandler {
    typealias InboundIn = NIOAny
    typealias OutboundIn = NIOAny
    typealias OutboundOut = NIOAny

    private var partner: GlueHandler?
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
