import Foundation
import NIOCore
import NIOPosix
import NIOHTTP1
import LoomSharedModels

/// Owns the listening sockets for the reverse-proxy endpoints — one channel per
/// endpoint, all on the engine's event-loop group.
///
/// Third sibling of `ProxyServer` and `SOCKSServer`, and deliberately the same
/// shape: same group, same flow store, same forwarder, and the *same*
/// `ProxyHandler` — only how the destination is decided differs, and that is a mode
/// on the handler rather than a second implementation of the capture path (see
/// `ProxyHandler.reverseUpstream`). Where the other two listeners require the client
/// to cooperate (an absolute request line, a SOCKS handshake), this one requires
/// nothing of it: it looks like the origin server.
final class ReverseProxyServer {
    private let group: EventLoopGroup
    /// Endpoint id → its listening channel. Only listening endpoints appear; one
    /// that failed to bind is remembered by the config, not here.
    private var channels: [UUID: Channel] = [:]

    init(group: EventLoopGroup) {
        self.group = group
    }

    /// Bind one endpoint and return the port actually bound. Throws the bind error —
    /// unlike the SOCKS listener, which fails open because it is a bonus port on a
    /// running proxy: an endpoint that didn't bind has *no* other way to serve its
    /// client, so a create that quietly returned would hand back an address that
    /// refuses every connection.
    @discardableResult
    func start(
        endpoint: ReverseProxyEndpoint,
        host: String = "127.0.0.1",
        store: FlowStore,
        forwarder: UpstreamForwarding,
        ca: CertificateAuthority?,
        config: InterceptionConfig
    ) async throws -> Int {
        // Rebinding an id that is already listening would leak the old channel and
        // leave two listeners for one endpoint.
        await stop(id: endpoint.id)
        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 256)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                if let ip = channel.remoteAddress?.ipAddress {
                    Task { await store.noteConnection(remoteIP: ip) }
                }
                let encoder = HTTPResponseEncoder()
                let decoder = ByteToMessageHandler(HTTPRequestDecoder(leftOverBytesStrategy: .forwardBytes))
                let proxy = ProxyHandler(
                    store: store, group: self.group, forwarder: forwarder,
                    ca: ca, config: config, reverseUpstream: endpoint
                )
                // The handler names are load-bearing: the WebSocket upgrade removes
                // them by name before splicing frames, so they have to match the
                // forward port's exactly (`ProxyHandler.startExchange`).
                return channel.pipeline.addHandler(encoder, name: "loom.http.encoder")
                    .flatMap { channel.pipeline.addHandler(decoder, name: "loom.http.decoder") }
                    .flatMap { channel.pipeline.addHandler(proxy, name: "loom.proxy") }
            }

        let channel = try await bootstrap.bind(host: host, port: endpoint.requestedPort).get()
        channels[endpoint.id] = channel
        return channel.localAddress?.port ?? endpoint.requestedPort
    }

    /// Stop one endpoint's listener. No-op when it isn't listening.
    func stop(id: UUID) async {
        guard let channel = channels.removeValue(forKey: id) else { return }
        try? await channel.close().get()
    }

    func stopAll() async {
        for id in channels.keys { await stop(id: id) }
    }

    func isListening(id: UUID) -> Bool { channels[id] != nil }
}
