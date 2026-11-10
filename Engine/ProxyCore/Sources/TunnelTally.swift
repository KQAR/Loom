import LoomSharedModels
import NIOCore

/// What one relayed tunnel carried, counted on the event loop both ends share (so:
/// no lock, and not `Sendable`). Reported once, when the second end goes away —
/// every byte either side will ever relay has been read by then.
final class TunnelTally {
    private var fromClient: Int
    private var toClient: Int
    private let openedAt = NIODeadline.now()
    private var openEnds = 2
    private let report: (TunnelTraffic) -> Void

    /// - Parameters alreadyFromClient/alreadyToClient: bytes Loom forwarded by hand
    ///   before the splice existed (a server-first splice hands over the greeting and
    ///   the client's prefix itself).
    init(alreadyFromClient: Int = 0, alreadyToClient: Int = 0, report: @escaping (TunnelTraffic) -> Void) {
        fromClient = alreadyFromClient
        toClient = alreadyToClient
        self.report = report
    }

    func count(_ bytes: Int, fromClient: Bool) {
        if fromClient { self.fromClient += bytes } else { toClient += bytes }
    }

    func endClosed() {
        openEnds -= 1
        guard openEnds == 0 else { return }
        let open = NIODeadline.now() - openedAt
        report(TunnelTraffic(
            bytesFromClient: fromClient, bytesToClient: toClient,
            openSeconds: Double(open.nanoseconds) / 1_000_000_000
        ))
    }
}

/// Sits in front of each `GlueHandler` half of a relayed tunnel and counts what
/// that side read. Its own handler rather than a field on the glue, because the
/// glue also splices WebSocket upgrades, whose bytes are already a flow.
///
/// The cost on the relay's hot path is one integer add and one extra pipeline hop
/// per read; the lock and the store hop are paid once per tunnel, at close.
final class TunnelByteCounter: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    typealias InboundOut = ByteBuffer

    private var tally: TunnelTally?
    private let readsFromClient: Bool

    init(tally: TunnelTally, readsFromClient: Bool) {
        self.tally = tally
        self.readsFromClient = readsFromClient
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        tally?.count(unwrapInboundIn(data).readableBytes, fromClient: readsFromClient)
        context.fireChannelRead(data)
    }

    /// `handlerRemoved`, not `channelInactive`: it fires exactly once whatever tore
    /// the pipeline down, so the tally can't wait forever on an end that never saw
    /// an inactive.
    func handlerRemoved(context: ChannelHandlerContext) {
        tally?.endClosed()
        tally = nil
    }
}
