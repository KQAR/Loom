import Foundation
import NIOCore
import NIOPosix

/// Owns the SOCKS5 listening socket. Sibling of `ProxyServer`: same event-loop
/// group, same flow store, same forwarder — only the way a client states its
/// destination differs, and `SOCKSConnectionHandler` normalizes that away before
/// the capture stack sees anything.
final class SOCKSServer {
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
                // Count the connecting device the moment the socket is accepted, the
                // same as the HTTP proxy port — a device is connected whether or not
                // its traffic ends up captured.
                if let ip = channel.remoteAddress?.ipAddress {
                    Task { await store.noteConnection(remoteIP: ip) }
                }
                return channel.pipeline.addHandler(
                    SOCKSConnectionHandler(
                        store: store, group: group, forwarder: forwarder,
                        ca: ca, config: config, observeTunnels: observeTunnels
                    ),
                    name: "loom.socks"
                )
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
