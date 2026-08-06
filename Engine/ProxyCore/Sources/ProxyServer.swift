import Foundation
import NIOCore
import NIOPosix
import NIOHTTP1

/// Owns the listening socket. Child pipelines are named so the CONNECT path
/// can strip HTTP framing before splicing a raw tunnel.
///
/// An actor rather than a class (`ReverseProxyServer` already was one): the bind
/// state is a `var channel` that only `ProxyEngine` — itself an actor — ever
/// touches, so under strict concurrency the choice is between proving that and
/// asserting it with `@unchecked Sendable`. Making the isolation real costs
/// nothing here, because every call site already awaits.
actor ProxyServer {
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
                // Count the connecting device (LAN peers only; loopback = this Mac)
                // the moment the socket is accepted — independent of whether its
                // traffic is ever captured, so a blind-tunneled HTTPS phone counts.
                if let ip = channel.remoteAddress?.ipAddress {
                    Task { await store.noteConnection(remoteIP: ip) }
                }
                // Handlers are constructed *inside* `makeCompletedFuture`, whose body is
                // not `@Sendable` — that is the whole reason for this shape. Built
                // outside and captured, each non-`Sendable` NIO handler crossed into a
                // `@Sendable` closure and the compiler said so. See ProxyCore/CLAUDE.md
                // § Sendable escape hatches.
                return channel.eventLoop.makeCompletedFuture {
                    let sync = channel.pipeline.syncOperations
                    try sync.addHandler(HTTPResponseEncoder(), name: "loom.http.encoder")
                    try sync.addHandler(
                        ByteToMessageHandler(HTTPRequestDecoder(leftOverBytesStrategy: .forwardBytes)),
                        name: "loom.http.decoder"
                    )
                    try sync.addHandler(
                        ProxyHandler(
                            store: store, group: group, forwarder: forwarder,
                            ca: ca, config: config, observeTunnels: observeTunnels
                        ),
                        name: "loom.proxy"
                    )
                }
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
