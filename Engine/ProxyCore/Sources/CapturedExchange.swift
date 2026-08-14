import Foundation
import NIOCore
import NIOHTTP1
import LoomSharedModels

/// The capture-and-forward core shared by the plain-HTTP path (`ProxyHandler`)
/// and the TLS-interception path (`TLSInterceptHandler`). Both saw an identical
/// exchange once framing was in place — capture the request, divert a WebSocket
/// upgrade to `WebSocketRelay`, otherwise resolve the source app and relay the
/// upstream response through `StreamRelay`. Only the URL derivation and the
/// WebSocket routing differ between the two, so those come in as `Routing`.
enum CapturedExchange {
    /// The bits that differ between the plain and MITM paths.
    struct Routing {
        /// Absolute URL to forward to.
        let url: URL
        /// Absolute URL string recorded on the captured flow.
        let urlString: String
        /// WebSocket upstream host / port / TLS, the origin-form path to replay,
        /// and the client-pipeline handlers to strip before splicing.
        let webSocketHost: String
        let webSocketPort: Int
        let webSocketUpstreamTLS: Bool
        let webSocketRequestPath: String
        let webSocketRemoveHandlerNames: [String]
    }

    /// A request recorded the moment its head was parsed, before anything decided
    /// what to do with it. Carried into `handle` so the exchange keeps that identity
    /// and that clock rather than starting a second flow.
    struct Observed {
        let id: UUID
        let startedAt: Date
    }

    /// What the client↔Loom hop was, which only the entry point knows.
    ///
    /// Both facts are per-connection and neither is derivable here: the HTTP
    /// version because an intercepted h2 request reaches this code as an HTTP/1.1
    /// head (the h2↔h1 codec built it), and the TLS version because on an h2
    /// stream channel the handler that knows it is on the *parent*. So the caller
    /// that terminated the connection states them, once, rather than every layer
    /// below guessing.
    struct ClientLeg {
        /// `HTTP/2` / `HTTP/1.1` / `HTTP/1.0` — what the client actually spoke.
        let httpVersion: String
        /// TLS the client negotiated with Loom's leaf, or nil for cleartext.
        let tlsVersion: String?

        init(httpVersion: String, tlsVersion: String? = nil) {
            self.httpVersion = httpVersion
            self.tlsVersion = tlsVersion
        }

        /// The client leg as a transport reading. Never empty — the HTTP version
        /// alone is on the request, so this carries only the TLS half; nil when
        /// there is nothing to say, so a plaintext exchange doesn't get an empty
        /// transport that reads as "measured, and nothing there".
        var transport: FlowTransport? {
            guard let tlsVersion else { return nil }
            return FlowTransport(clientTLSVersion: tlsVersion)
        }
    }

    /// Record the request as soon as its **head** is parsed.
    ///
    /// The flow used to be created on the first body chunk (or on `.end` for a
    /// bodyless request), which meant a request that arrived and then stalled —
    /// an h2 body blocked by flow control, an upload the client never finished —
    /// recorded *nothing at all*. On every surface that is identical to a client
    /// that never ran, which is the failure this project already refuses to ship
    /// for pass-throughs (`TunneledHostLog`) and for refused connections
    /// (`RefusalLog`). A request Loom has parsed is a fact Loom holds; it belongs
    /// in the capture the moment it exists, in-flight, not once it succeeds.
    ///
    /// Found on the wire: a phone uploaded 31 KB of HEADERS+DATA to Loom, got no
    /// response, and the capture showed no flow — so "the proxy lost it" and "the
    /// app never asked" could not be told apart, by a human or an agent.
    static func observe(
        channel: Channel, head: HTTPRequestHead, urlString: String, store: FlowStore,
        clientLeg: ClientLeg
    ) -> Observed {
        let observed = Observed(id: UUID(), startedAt: Date())
        let headers = HTTPUtil.headerPairs(head.headers)
        let request = CapturedRequest(
            method: head.method.rawValue, url: urlString,
            httpVersion: clientLeg.httpVersion, headers: headers, body: nil
        )
        let device = device(channel: channel, headers: headers)
        let flow = Flow(
            id: observed.id, request: request, startedAt: observed.startedAt,
            sourceApp: remoteApp(headers: headers, device: device), sourceDevice: device,
            transport: clientLeg.transport
        )
        Task { await store.upsert(flow) }
        return observed
    }

    static func handle(
        channel: Channel,
        head: HTTPRequestHead,
        body: RequestBody,
        bodyCapture: RequestBodyCapture?,
        routing: Routing,
        store: FlowStore,
        forwarder: UpstreamForwarding,
        observed: Observed,
        clientLeg: ClientLeg
    ) {
        let headers = HTTPUtil.headerPairs(head.headers)
        // For a streamed body the bytes aren't known yet; `bodyCapture` fills them in
        // as they flow, and `StreamRelay` reads the complete copy on the response
        // upserts (the request finishes before the response head by HTTP ordering).
        let initialBody: Data?
        switch body.source {
        case let .bytes(data): initialBody = data
        case .stream: initialBody = nil
        }
        // Same story for the trailer section: a streamed request's arrives after the
        // last chunk, so it is nil here and `StreamRelay` backfills it from the box.
        let capturedRequest = CapturedRequest(
            method: head.method.rawValue, url: routing.urlString,
            httpVersion: clientLeg.httpVersion, headers: headers, body: initialBody,
            trailers: body.trailers?.current
        )
        // Identity and clock come from `observe`, which already put this request in
        // the capture: an exchange must continue that flow, never open a second one.
        let flowID = observed.id
        let startedAt = observed.startedAt
        let keepAlive = head.isKeepAlive
        let method = head.method.rawValue
        let sourcePort = channel.remoteAddress?.port
        let proxyPort = channel.localAddress?.port
        // Device attribution (remote IP + UA type) is pure and loop-safe, unlike
        // the libproc `sourceApp` scan below — compute it here and capture it.
        let sourceDevice = device(channel: channel, headers: headers)
        // Only a loopback peer has a local pid to find. For a LAN device the scan
        // can't succeed, and its remote ephemeral port could collide with a local
        // socket's local port and mis-attribute a phone's traffic to a Mac app.
        let isLoopbackPeer = sourceDevice?.kind == .local
        // …which is exactly why a LAN device needs the other kind of attribution.
        // Known here and now (it is a header, already parsed), so unlike the
        // libproc path there is nothing to wait for and nothing to backfill.
        let remoteApp = remoteApp(headers: headers, device: sourceDevice)

        // A WebSocket upgrade is spliced (frames captured) rather than fetched.
        if WebSocketRelay.isUpgrade(head) {
            // A LAN peer has no app to resolve, so skip the pause/Task/hop-back
            // dance entirely and splice straight away.
            guard isLoopbackPeer else {
                WebSocketRelay.start(
                    clientChannel: channel, head: head, requestPath: routing.webSocketRequestPath,
                    host: routing.webSocketHost, port: routing.webSocketPort,
                    upstreamTLS: routing.webSocketUpstreamTLS,
                    removeHandlerNames: routing.webSocketRemoveHandlerNames,
                    flowID: flowID, request: capturedRequest, startedAt: startedAt,
                    sourceApp: remoteApp, sourceDevice: sourceDevice, store: store
                )
                return
            }
            // Pause client reads *now* (we're on the event loop) so frames can't
            // reach a half-removed pipeline while we resolve the source app — that
            // resolution is a blocking libproc scan that must run off the loop, so
            // it happens in a Task before hopping back to start the splice.
            _ = channel.setOption(ChannelOptions.autoRead, value: false)
            let eventLoop = channel.eventLoop
            Task {
                let sourceApp = await ProcessResolver.resolve(
                    sourcePort: sourcePort, proxyPort: proxyPort, isLoopbackPeer: isLoopbackPeer,
                    connectionOpenedAt: startedAt
                )
                eventLoop.execute {
                    WebSocketRelay.start(
                        clientChannel: channel, head: head, requestPath: routing.webSocketRequestPath,
                        host: routing.webSocketHost, port: routing.webSocketPort,
                        upstreamTLS: routing.webSocketUpstreamTLS,
                        removeHandlerNames: routing.webSocketRemoveHandlerNames,
                        flowID: flowID, request: capturedRequest, startedAt: startedAt,
                        sourceApp: sourceApp, sourceDevice: sourceDevice, store: store
                    )
                }
            }
            return
        }

        Task {
            // Record the pending flow *first*, before the blocking libproc scan, so
            // the row (and its in-flight spinner) appears the instant the request
            // head is parsed rather than after `ProcessResolver.resolve` returns.
            // This also keeps the synchronous scan off the before-first-paint path.
            await store.upsert(Flow(
                id: flowID, request: capturedRequest, startedAt: startedAt,
                sourceApp: remoteApp, sourceDevice: sourceDevice, transport: clientLeg.transport
            ))

            // Whether forwarding must wait for the resolver: only when something
            // in the chain matches on the source app (an app-scoped rule or
            // breakpoint evaluated against nil fails closed — it would silently
            // skip the very rule the operator armed). Otherwise the resolver's
            // worst case — a full libproc pid/fd sweep, tens to hundreds of ms,
            // serialized across a burst — was added to every request's TTFB for
            // attribution the UI is happy to backfill.
            let sourceApp: SourceApp?
            if let remoteApp {
                // A LAN device: there is no process to resolve and no resolver to
                // wait for, so the attribution the headers already gave is final.
                sourceApp = remoteApp
            } else if forwarder.requiresSourceAppResolution {
                // `startedAt` stands in for the connection's open time: for a new
                // connection they are milliseconds apart, and for a keep-alive one it
                // is *later*, which only ever costs an extra sweep the port cache
                // then absorbs. Passing it is what stops a burst of short-lived
                // clients from failing an app-scoped rule closed.
                sourceApp = await ProcessResolver.resolve(
                    sourcePort: sourcePort, proxyPort: proxyPort, isLoopbackPeer: isLoopbackPeer,
                    connectionOpenedAt: startedAt
                )
                if sourceApp != nil {
                    // Safe as a whole-flow re-upsert: forwarding hasn't started,
                    // so no response upsert can interleave.
                    await store.upsert(Flow(
                        id: flowID, request: capturedRequest, startedAt: startedAt,
                        sourceApp: sourceApp, sourceDevice: sourceDevice, transport: clientLeg.transport
                    ))
                }
            } else {
                sourceApp = nil
                // Resolve concurrently and backfill just the attribution —
                // `attributeSourceApp` merges into whatever the exchange has
                // recorded by the time the resolver answers, and `upsert`
                // preserves a landed attribution against the relay's later
                // sourceApp-nil upserts.
                Task {
                    if let app = await ProcessResolver.resolve(
                        sourcePort: sourcePort, proxyPort: proxyPort, isLoopbackPeer: isLoopbackPeer,
                        connectionOpenedAt: startedAt
                    ) {
                        await store.attributeSourceApp(id: flowID, app)
                    }
                }
            }

            await StreamRelay.relay(
                // The origin travels with the request, so a rule or breakpoint scoped to
                // one app/device is evaluated against the client that actually sent it.
                // On the concurrent path `app` is nil by construction — nothing in the
                // chain matches on it (device scoping needs no resolver).
                stream: forwarder.forwardStream(
                    method: method, url: routing.url, headers: headers, body: body,
                    origin: RequestOrigin(app: sourceApp, device: sourceDevice),
                    // What the client negotiated with Loom decides the upstream leg:
                    // an h2 client gets an h2 origin connection when the origin will
                    // have one. See `ClientWireProtocol` for why this is gated on the
                    // client rather than on what the origin offers.
                    clientProtocol: ClientWireProtocol(
                        httpVersion: clientLeg.httpVersion, clientTLSVersion: clientLeg.tlsVersion
                    )
                ),
                channel: channel, keepAlive: keepAlive, flowID: flowID,
                request: capturedRequest, startedAt: startedAt, sourceApp: sourceApp, sourceDevice: sourceDevice,
                store: store, bodyCapture: bodyCapture, requestTrailers: body.trailers,
                clientTransport: clientLeg.transport
            )
        }
    }

    /// The app behind a request that has no local process to resolve — i.e. every
    /// request from a LAN device.
    ///
    /// Scoped to LAN peers on purpose. A loopback request has a pid, and libproc's
    /// answer is a fact where a `User-Agent` is a claim; falling back to the header
    /// when the resolver comes up empty would quietly mix the two kinds of
    /// attribution on the surface where the exact one is available. A local flow
    /// the resolver could not attribute stays unattributed, as before.
    ///
    /// Pure and synchronous — it reads a header this code has already parsed — so
    /// unlike the libproc sweep it adds nothing to the exchange's latency and needs
    /// no backfill.
    private static func remoteApp(headers: [HeaderPair], device: SourceDevice?) -> SourceApp? {
        guard device?.kind == .lan else { return nil }
        let userAgent = headers.first { $0.name.lowercased() == "user-agent" }?.value
        return UserAgentParser.app(userAgent).map(SourceApp.fromUserAgent)
    }

    /// Identify the originating device from the connection's remote IP, typed by
    /// its `User-Agent`. Pure — safe to call on the event loop.
    private static func device(channel: Channel, headers: [HeaderPair]) -> SourceDevice? {
        guard let ip = channel.remoteAddress?.ipAddress else { return nil }
        let userAgent = headers.first { $0.name.lowercased() == "user-agent" }?.value
        let parsed = UserAgentParser.parse(userAgent)
        return SourceDevice(ip: ip, kind: SourceDevice.kind(forIP: ip), platform: parsed.platform, client: parsed.client)
    }
}
