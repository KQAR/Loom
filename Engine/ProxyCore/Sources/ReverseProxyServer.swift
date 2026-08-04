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
final class ReverseProxyServer: @unchecked Sendable {
    private let group: EventLoopGroup
    /// Endpoint id → its listening channel. Only listening endpoints appear; one
    /// that failed to bind is remembered by the config, not here.
    ///
    /// Lock-guarded, and the lock is **never held across an `await`**: every mutation
    /// below takes the channel out (or puts it in) and then does the I/O outside.
    ///
    /// Why a lock at all, when this is only reached from the `ProxyEngine` actor:
    /// these are `async` methods on a plain class, so their bodies do **not** run on
    /// the actor's executor. Two engine calls that overlap — an agent creating one
    /// endpoint while deleting another, which the MCP surface allows — interleave in
    /// here on different threads.
    private let lock = NSLock()
    private var channels: [UUID: Channel] = [:]

    init(group: EventLoopGroup) {
        self.group = group
    }

    private func takeChannel(id: UUID) -> Channel? {
        lock.lock()
        defer { lock.unlock() }
        return channels.removeValue(forKey: id)
    }

    /// Named `remember` rather than `store`: `start(…)` already takes a `store:`
    /// (the FlowStore), and the parameter shadows a method of that name.
    private func remember(_ channel: Channel, id: UUID) {
        lock.lock()
        defer { lock.unlock() }
        channels[id] = channel
    }

    /// Remove and return every channel at once — the snapshot `stopAll` needs.
    private func takeAllChannels() -> [Channel] {
        lock.lock()
        defer { lock.unlock() }
        let all = Array(channels.values)
        channels.removeAll()
        return all
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
        remember(channel, id: endpoint.id)
        return channel.localAddress?.port ?? endpoint.requestedPort
    }

    /// Stop one endpoint's listener. No-op when it isn't listening.
    func stop(id: UUID) async {
        guard let channel = takeChannel(id: id) else { return }
        try? await channel.close().get()
    }

    /// Stop every listener.
    ///
    /// The channels are taken out **first**, in one step, and only then closed. The
    /// obvious spelling — `for id in channels.keys { await stop(id: id) }` — iterates a
    /// lazy view over the dictionary's storage while `stop` removes from that same
    /// storage, across a suspension point: undefined behaviour, and the cause of the
    /// intermittent ThreadSanitizer failure this suite showed from the moment it
    /// landed (a corrupt read surfacing as a race report in NIO's continuation bridge
    /// plus an `abort()`, attributed to whichever test was unlucky). Every
    /// `engine.stop()` ran it, which is why making test teardown deterministic made it
    /// *more* frequent rather than less.
    func stopAll() async {
        for channel in takeAllChannels() {
            try? await channel.close().get()
        }
    }

    func isListening(id: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return channels[id] != nil
    }
}
