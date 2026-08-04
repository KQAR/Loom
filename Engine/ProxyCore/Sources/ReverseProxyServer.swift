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
///
/// An **actor**, not a lock-guarded class, unlike the other holders of mutable state
/// in this module. The distinction is which side reads it: `RulesConfig`,
/// `InterceptionConfig` and `RefusalLog` are read *on the event loop* for every
/// request, where nothing can be awaited, so they have to be lock-based;
/// `ReservedPorts` has to be writable synchronously at launch before an executor
/// exists. Neither applies here — every caller is an `await` from the `ProxyEngine`
/// actor — so the state is protected by construction instead of by remembering to
/// never hold a lock across a suspension.
actor ReverseProxyServer {
    private let group: EventLoopGroup
    /// Endpoint id → its listening channel. Only listening endpoints appear; one
    /// that failed to bind is remembered by the config, not here.
    private var channels: [UUID: Channel] = [:]

    init(group: EventLoopGroup) {
        self.group = group
    }

    private func takeChannel(id: UUID) -> Channel? {
        channels.removeValue(forKey: id)
    }

    /// Record the channel for `id`, returning any channel it displaced.
    ///
    /// Named `remember` rather than `store` because `start(…)` takes a `store:`
    /// (the FlowStore) that would shadow it. The return value is the reentrancy
    /// guard: actor isolation makes the dictionary write safe, but it does **not**
    /// serialize `start`'s check-bind-record sequence across its `await` on `bind()`.
    /// Two overlapping starts for one id would both bind, and the loser used to be
    /// overwritten here — a listening socket with nothing left holding a reference to
    /// close it. The caller closes what it displaces.
    private func remember(_ channel: Channel, id: UUID) -> Channel? {
        let displaced = channels[id]
        channels[id] = channel
        return displaced
    }

    /// Remove and return every channel at once — the snapshot `stopAll` needs.
    private func takeAllChannels() -> [Channel] {
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
        // Fast path for the ordinary rebind: close the old listener before binding
        // rather than after, so one endpoint isn't briefly served by two sockets.
        // `remember` still closes a displacement, for the interleaving this can't see.
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
        // Close whatever this displaced (see `remember`): a concurrent start for the
        // same id would otherwise leave a bound socket nobody can reach.
        if let displaced = remember(channel, id: endpoint.id) {
            try? await displaced.close().get()
        }
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
        channels[id] != nil
    }
}
