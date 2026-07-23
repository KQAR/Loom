import Foundation
import NIOCore
import NIOPosix
import NIOHTTP1

/// Owns the listening socket. Child pipelines are named so the CONNECT path
/// can strip HTTP framing before splicing a raw tunnel.
final class ProxyServer {
    private let group: EventLoopGroup
    private var channel: Channel?

    init(group: EventLoopGroup) {
        self.group = group
    }

    func start(
        host: String,
        port: Int,
        store: FlowStore,
        forwarder: UpstreamForwarding,
        ca: CertificateAuthority?,
        config: InterceptionConfig,
        observeTunnels: Bool = false
    ) async throws -> Int {
        let group = self.group
        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 256)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                let encoder = HTTPResponseEncoder()
                let decoder = ByteToMessageHandler(HTTPRequestDecoder(leftOverBytesStrategy: .forwardBytes))
                let proxy = ProxyHandler(store: store, group: group, forwarder: forwarder, ca: ca, config: config, observeTunnels: observeTunnels)
                return channel.pipeline.addHandler(encoder, name: "loom.http.encoder")
                    .flatMap { channel.pipeline.addHandler(decoder, name: "loom.http.decoder") }
                    .flatMap { channel.pipeline.addHandler(proxy, name: "loom.proxy") }
            }

        let channel = try await bootstrap.bind(host: host, port: port).get()
        self.channel = channel
        return channel.localAddress?.port ?? port
    }

    func stop() async {
        try? await channel?.close().get()
        channel = nil
    }
}
