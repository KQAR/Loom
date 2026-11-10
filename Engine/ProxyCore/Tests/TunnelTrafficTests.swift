import Foundation
import NIOCore
import NIOPosix
import Testing
@testable import LoomProxyCore
import LoomSharedModels

/// What a relayed tunnel carried. An unread relay records no flow, so before this
/// "connected and sent nothing" and "moved 3 MB" were the same entry.
@Suite("Relayed tunnel traffic", .timeLimit(.minutes(1)))
struct TunnelTrafficTests {
    @Test func closedConnectionsFoldIntoTheHostEntry() throws {
        let log = TunneledHostLog()
        log.record(host: "ssh.test", port: 22, reason: .notTLSOrHTTP)
        log.recordTraffic(host: "SSH.test", port: 22, TunnelTraffic(bytesFromClient: 10, bytesToClient: 100, openSeconds: 2))
        log.recordTraffic(host: "ssh.test", port: 22, TunnelTraffic(bytesFromClient: 5, bytesToClient: 0, openSeconds: 7))

        let traffic = try #require(log.snapshot().hosts.first?.traffic)
        #expect(traffic == TunnelTraffic(bytesFromClient: 15, bytesToClient: 100, connections: 2, openSeconds: 7))
    }

    @Test func trafficNeverResurrectsAClearedHost() {
        // The entry is written when the relay starts; a tunnel that closes after
        // `clearFlows` must not bring the host back.
        let log = TunneledHostLog()
        log.recordTraffic(host: "gone.test", port: 443, TunnelTraffic(bytesFromClient: 1, bytesToClient: 1, openSeconds: 1))
        #expect(log.snapshot().hosts.isEmpty)
    }

    @Test func anOutOfScopeCONNECT_reportsWhatItRelayed_onTheHostAndTheRow() async throws {
        let engine = ProxyEngine(
            forwarder: StubForwarder(status: 200, body: Data()), caStore: InMemoryCAStore()
        )
        let port = try await engine.start(port: 0, observeTunnels: true)
        await engine.setSSLScope(SSLScope(enabled: true, include: []))

        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { shutdownBlocking(group) }
        let origin = try await ServerBootstrap(group: group)
            .childChannelInitializer { $0.pipeline.addHandler(Echo()) }
            .bind(host: "127.0.0.1", port: 0).get()
        defer { origin.close(promise: nil) }
        let originPort = try #require(origin.localAddress?.port)

        let loop = group.next()
        let acked = loop.makePromise(of: Void.self)
        let echoed = loop.makePromise(of: Void.self)
        let connect = CONNECTAckHandler(
            request: "CONNECT 127.0.0.1:\(originPort) HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n",
            acked: acked
        )
        let client = try await ClientBootstrap(group: group)
            .channelInitializer { $0.pipeline.addHandler(connect) }
            .connect(host: "127.0.0.1", port: port).get()
        try await acked.futureResult.get()
        try await client.pipeline.removeHandler(connect).get()

        let payload = 4_096
        try await client.pipeline.addHandler(EchoedBytes(expecting: payload, done: echoed)).get()
        var buffer = client.allocator.buffer(capacity: payload)
        buffer.writeRepeatingByte(0x2A, count: payload)
        try await client.writeAndFlush(buffer).get()
        try await echoed.futureResult.get()
        try await client.close().get()

        // Reported at close, asynchronously to the client's own close.
        var entry: TunneledHost?
        for _ in 0 ..< 250 {
            entry = await engine.tunneledHosts().hosts.first { $0.port == originPort && $0.traffic != nil }
            if entry != nil { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let traffic = try #require(entry?.traffic)
        // Exactly the tunnel's bytes: Loom's own `200 Connection Established` ack is
        // not relayed traffic and must not be counted.
        #expect(traffic.bytesFromClient == payload)
        #expect(traffic.bytesToClient == payload)
        #expect(traffic.connections == 1)
        #expect(traffic.openSeconds > 0)

        var row: Flow?
        for _ in 0 ..< 250 {
            row = await engine.recentFlows(limit: 50).first {
                $0.tunnelDiagnostic?.port == originPort && $0.tunnelDiagnostic?.traffic != nil
            }
            if row != nil { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(row?.tunnelDiagnostic?.traffic?.bytesToClient == payload)
        await engine.stopForTest()
    }
}

private final class Echo: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        context.writeAndFlush(data, promise: nil)
    }
}

/// Fulfils `done` once `expecting` bytes have arrived.
private final class EchoedBytes: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    private let expecting: Int
    private let done: EventLoopPromise<Void>
    private var seen = 0

    init(expecting: Int, done: EventLoopPromise<Void>) {
        self.expecting = expecting
        self.done = done
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        seen += unwrapInboundIn(data).readableBytes
        if seen >= expecting { done.succeed(()) }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        done.fail(error)
    }
}
