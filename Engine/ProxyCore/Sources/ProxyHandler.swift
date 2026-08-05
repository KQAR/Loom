import Foundation
import NIOCore
import NIOPosix
import NIOHTTP1
import NIOHTTP2
import NIOTLS
import NIOSSL
import LoomSharedModels

/// Terminates one proxied client connection. For plain HTTP it captures the
/// exchange and forwards it. For CONNECT it either MITM-decrypts the TLS (when
/// the host is in the SSL-proxying scope and a CA is available) or opens a blind
/// TCP tunnel (pinned / out-of-scope / interception off).
// @unchecked Sendable: event-loop confined, no lock — see ProxyCore/CLAUDE.md
// § Sendable escape hatches for what that forbids inside a `Task {}`.
final class ProxyHandler: ChannelInboundHandler, RemovableChannelHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private let store: FlowStore
    private let group: EventLoopGroup
    private let forwarder: UpstreamForwarding
    private let ca: CertificateAuthority?
    private let config: InterceptionConfig
    /// When true, an un-decrypted (blind) CONNECT tunnel is recorded as a flow so
    /// a consumer can see the HTTPS activity even though it wasn't MITM-decrypted.
    /// Off by default — the app UI doesn't want CONNECT noise; embedders opt in.
    private let observeTunnels: Bool
    /// Set when this handler is serving a **reverse-proxy endpoint** rather than the
    /// forward-proxy port: the client believes it is talking to an ordinary web
    /// server, so it sends origin-form request lines and Loom supplies the
    /// destination from configuration instead of from the request.
    ///
    /// Deliberately a mode on this handler rather than a second handler. Everything
    /// after "which URL is this going to" — body streaming and its back-pressure,
    /// the capture, rules, breakpoints, the WebSocket splice — must behave
    /// identically on both entry points, and the way that stops being true is by
    /// having two copies of it (the same reasoning `MITMPipeline` records for the
    /// HTTP and SOCKS entry points).
    private let reverseUpstream: ReverseProxyEndpoint?

    private var requestHead: HTTPRequestHead?
    private var requestURL: URL?
    private var connectHead: HTTPRequestHead?
    /// Live bridge for the current request's streamed body — created lazily on the
    /// first body chunk (so h2 bodies with no Content-Length still stream); nil for a
    /// bodyless request. Chunks are pumped in and pulled by the forwarder under
    /// back-pressure.
    private var bodyBridge: RequestBodyBridge?
    /// Set when the request head was malformed so the trailing body/end are ignored.
    private var droppingRequest = false

    init(
        store: FlowStore,
        group: EventLoopGroup,
        forwarder: UpstreamForwarding,
        ca: CertificateAuthority?,
        config: InterceptionConfig,
        observeTunnels: Bool = false,
        reverseUpstream: ReverseProxyEndpoint? = nil
    ) {
        self.store = store
        self.group = group
        self.forwarder = forwarder
        self.ca = ca
        self.config = config
        self.observeTunnels = observeTunnels
        self.reverseUpstream = reverseUpstream
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case let .head(head):
            if head.method == .CONNECT, reverseUpstream == nil {
                // Defer the pipeline surgery until `.end`, so the decoder has
                // finished emitting the CONNECT's HTTP parts before we swap it out.
                connectHead = head
                return
            }
            guard let resolved = resolveDestination(head) else {
                refuse(context: context, head: head)
                droppingRequest = true
                return
            }
            requestHead = resolved.head
            requestURL = resolved.url
        case var .body(chunk):
            if droppingRequest { return }
            // First body chunk: begin streaming. Pausing auto-read (mirrors the
            // TLS-swap pause) means the only reads are the ones the bridge asks for as
            // the forwarder drains, so a fast uploader can't outrun a slow upstream.
            if bodyBridge == nil {
                guard let head = requestHead, let url = requestURL else { return }
                let bridge = RequestBodyBridge(capture: RequestBodyCapture())
                bridge.attach(channel: context.channel)
                bodyBridge = bridge
                _ = context.channel.setOption(ChannelOptions.autoRead, value: false)
                startExchange(channel: context.channel, head: head, url: url,
                              body: .stream(bridge.chunks, contentLength: RequestBodyStreaming.contentLength(head)),
                              capture: bridge.capture)
            }
            if let bytes = chunk.readBytes(length: chunk.readableBytes) { bodyBridge?.yield(Data(bytes)) }
        case .end:
            if let connectHead {
                self.connectHead = nil
                handleConnect(context: context, head: connectHead)
                return
            }
            if let bodyBridge {
                bodyBridge.finish()
                self.bodyBridge = nil
                _ = context.channel.setOption(ChannelOptions.autoRead, value: true) // resume for keep-alive
                requestHead = nil; requestURL = nil
                return
            }
            if droppingRequest { droppingRequest = false; requestHead = nil; requestURL = nil; return }
            guard let head = requestHead, let url = requestURL else { return }
            startExchange(channel: context.channel, head: head, url: url, body: .bytes(nil), capture: nil)
            requestHead = nil; requestURL = nil
        }
    }

    /// A body stream still in flight when the connection goes away has to be
    /// terminated here — nothing else will. See `RequestBodyBridge.abort(reason:)`
    /// for why letting it deinit unfinished is fatal.
    func channelInactive(context: ChannelHandlerContext) {
        abortBodyStream(reason: "connection closed")
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        abortBodyStream(reason: "\(error)")
        context.fireErrorCaught(error)
    }

    private func abortBodyStream(reason: String) {
        guard let bridge = bodyBridge else { return }
        bodyBridge = nil
        requestHead = nil
        requestURL = nil
        bridge.abort(reason: reason)
    }

    // MARK: - Refusals

    /// Turn away a request this port can't serve, and say why in all three places
    /// that have a reader: the HTTP response (whoever ran the client), `os_log` (the
    /// human with Console open) and `RefusalLog` (the agent, via
    /// `get_proxy_status.recentRefusals`).
    ///
    /// The third one is the point. The old behaviour wrote a bare
    /// `400 expected absolute request URI` to the socket and recorded nothing, so an
    /// agent asking why nothing was captured saw an empty flow list and a status
    /// reporting no problem — indistinguishable from a client that never ran, which
    /// is the exact ambiguity the SOCKS listener already fixed for its own refusals.
    private func refuse(context: ChannelHandlerContext, head: HTTPRequestHead) {
        let reason = Self.refusalReason(for: head, reverseUpstream: reverseUpstream)
        Log.proxy.error("\(reason, privacy: .public)")
        RefusalLog.shared.record(ConnectionRefusal(
            listener: reverseUpstream == nil ? .http : .reverseProxy,
            peer: context.channel.remoteAddress.map { String(describing: $0) },
            reason: reason
        ))
        HTTPUtil.writeResponse(channel: context.channel, status: 400, headers: [],
                               body: Data("Loom: \(reason)\n".utf8), keepAlive: false)
    }

    /// Why the request line was unusable, in terms the operator can act on.
    ///
    /// Origin-form is worth its own branch rather than a generic "malformed": it is
    /// not a malformed proxy request at all, it is a *well-formed request to a web
    /// server*, which means the client was pointed at Loom as if Loom were the
    /// origin. A dev server forwarding `/api` to `http://127.0.0.1:9090` is the
    /// common way to arrive here, and the fix is a different one from "your client
    /// sent garbage", so the two must not read the same.
    /// On a reverse endpoint the advice inverts — the client is *supposed* to send
    /// origin-form there — so the two ports must not share one message.
    static func refusalReason(for head: HTTPRequestHead, reverseUpstream: ReverseProxyEndpoint? = nil) -> String {
        let target = clamp(head.uri)
        // Both halves are client-supplied and land in a durable-ish log; clamp them
        // so a pathological URL can't bloat every refusal entry.
        let host = head.headers.first(name: "Host").map { clamp($0) } ?? "absent"
        if let endpoint = reverseUpstream {
            let upstream = clamp(endpoint.upstream)
            guard head.method == .CONNECT else {
                // Only reachable when the configured upstream can't be joined with the
                // request target — a hand-edited config file, since creation validates.
                return """
                Reverse-proxy endpoint refused: could not build an upstream URL from \
                \(upstream) and request target \(target). The endpoint's upstream is not \
                usable; recreate it with a valid origin. Nothing was captured.
                """
            }
            return """
            Reverse-proxy endpoint refused: CONNECT \(target). This port stands in for \
            \(upstream) as an ordinary web server, not as a proxy — a client should request \
            paths on it directly over plain HTTP (GET /api/… to http://127.0.0.1:<port>), \
            and Loom does the TLS to the upstream. To use Loom as a proxy instead, point the \
            client at the forward-proxy port. Nothing was captured for this request.
            """
        }
        guard head.uri.hasPrefix("/") else {
            return """
            HTTP proxy refused: request target \(target) is neither an absolute URL \
            (http://host/path, what a forward proxy expects) nor origin-form (/path). \
            Nothing was captured for it.
            """
        }
        return """
        HTTP proxy refused: request line was origin-form — \(head.method) \(target) with \
        Host: \(host) — but this is Loom's forward-proxy port, which needs the absolute form \
        (\(head.method) http://\(host)\(target)). A client that sends origin-form here was \
        pointed at Loom as if Loom were the destination server; the usual case is a dev \
        server whose proxy target is Loom's own port. Aim the client at Loom as a proxy \
        instead (curl -x 127.0.0.1:<port>, HTTP_PROXY/HTTPS_PROXY, or the system proxy \
        switch). Nothing was captured for this request.
        """
    }

    private static func clamp(_ value: String, limit: Int = 120) -> String {
        value.count <= limit ? value : value.prefix(limit) + "…"
    }

    // MARK: - Where this request is going

    /// Resolve the upstream URL for a request, and the head to forward with it.
    /// `nil` means the request can't be served on this port at all (→ `refuse`).
    ///
    /// The two ports answer the question from opposite ends. On the forward-proxy
    /// port the *client* states the destination, so the request line must be
    /// absolute. On a reverse endpoint the *configuration* states it, so the client's
    /// own target only supplies path and query.
    private func resolveDestination(_ head: HTTPRequestHead) -> (head: HTTPRequestHead, url: URL)? {
        guard let endpoint = reverseUpstream else {
            guard let url = URL(string: head.uri), url.scheme != nil else { return nil }
            return (head, url)
        }
        guard let url = endpoint.forwardURL(requestTarget: Self.requestTarget(head.uri)) else { return nil }
        var rewritten = head
        // Rewrite the request line to the absolute upstream URL: it is what the flow
        // records, so a captured reverse-proxied exchange carries the URL the
        // developer thinks in terms of (`https://api.example.com/users`) rather than
        // `127.0.0.1:9200`. Rules and breakpoints then match it like any other flow —
        // if the local port leaked into the URL here, every rule an agent wrote
        // against the real host would silently stop matching.
        rewritten.uri = url.absoluteString
        if !endpoint.keepHostHeader {
            // Drop it rather than compute a replacement: the forwarder already
            // synthesizes `Host` (with the port elided when it's the scheme default)
            // for a request that arrives without one, and that is the same code path
            // a map-remote rule's default uses. Two ways to spell "follow the new
            // origin" is one too many.
            rewritten.headers.remove(name: "Host")
        }
        return (rewritten, url)
    }

    /// The path+query of a request target, whichever form it arrived in. A client
    /// that sends absolute-form to a reverse endpoint is still talking *to that
    /// endpoint*; honoring its URL would route past the upstream the endpoint exists
    /// to reach, which is the one thing a reverse proxy must not do.
    private static func requestTarget(_ uri: String) -> String {
        guard let url = URL(string: uri), url.scheme != nil else { return uri }
        return originForm(url)
    }

    // MARK: - Plain HTTP forwarding

    /// Upstream port + TLS for a WebSocket upgrade, from the resolved destination
    /// URL's scheme. On the forward port the client states it as `ws`/`wss`; on a
    /// reverse endpoint the resolved URL carries the configured upstream's
    /// `http`/`https`, so both spellings of "TLS" must count — matching on the
    /// literal `wss` alone sent a reverse-proxied upgrade to an `https` upstream
    /// as plaintext to port 80.
    static func webSocketRouting(for url: URL) -> (port: Int, tls: Bool) {
        let scheme = url.scheme?.lowercased() ?? ""
        let tls = scheme == "wss" || scheme == "https"
        return (url.port ?? (tls ? 443 : 80), tls)
    }

    private func startExchange(channel: Channel, head: HTTPRequestHead, url: URL, body: RequestBody, capture: RequestBodyCapture?) {
        let ws = Self.webSocketRouting(for: url)
        CapturedExchange.handle(
            channel: channel, head: head, body: body, bodyCapture: capture,
            routing: CapturedExchange.Routing(
                url: url,
                urlString: head.uri,
                webSocketHost: url.host ?? "",
                webSocketPort: ws.port,
                webSocketUpstreamTLS: ws.tls,
                webSocketRequestPath: Self.originForm(url),
                webSocketRemoveHandlerNames: ["loom.http.encoder", "loom.http.decoder", "loom.proxy"]
            ),
            store: store, forwarder: forwarder
        )
    }

    /// Origin-form request target (path + query) for an absolute proxied URL.
    private static func originForm(_ url: URL) -> String {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url.path.isEmpty ? "/" : url.path
        }
        let path = components.percentEncodedPath.isEmpty ? "/" : components.percentEncodedPath
        if let query = components.percentEncodedQuery { return "\(path)?\(query)" }
        return path
    }

    // MARK: - CONNECT

    private func handleConnect(context: ChannelHandlerContext, head: HTTPRequestHead) {
        let (host, port) = Self.parseAuthority(head.uri)
        if let ca, config.shouldIntercept(host: host) {
            interceptTLS(context: context, host: host, port: port, ca: ca)
        } else {
            openTunnel(context: context, host: host, port: port)
        }
    }

    private static func parseAuthority(_ uri: String) -> (host: String, port: Int) {
        let parts = uri.split(separator: ":")
        let host = String(parts.first ?? "")
        let port = parts.count > 1 ? (Int(parts[1]) ?? 443) : 443
        return (host, port)
    }

    // MARK: - MITM interception

    /// Acknowledge the CONNECT, then swap the plaintext HTTP framing for a TLS
    /// server (presenting the host's leaf) followed by fresh HTTP framing and the
    /// capturing handler. Auto-read is paused across the swap so the client's
    /// ClientHello can't reach the old HTTP decoder mid-reconfiguration.
    private func interceptTLS(context: ChannelHandlerContext, host: String, port: Int, ca: CertificateAuthority) {
        let sslContext: NIOSSLContext
        do {
            sslContext = try ca.serverContext(for: host)
        } catch {
            // Fail open: blind-tunnel so the site still works, but record why this
            // host wasn't intercepted (otherwise "nothing captured" is a mystery).
            Log.tls.error("Leaf mint failed for \(host, privacy: .public); blind-tunneling: \(String(describing: error))")
            openTunnel(context: context, host: host, port: port)
            return
        }

        let channel = context.channel
        let store = self.store
        let forwarder = self.forwarder
        let pipeline = channel.pipeline

        // Pause reads until the TLS handler is installed so the client's ClientHello
        // can't reach a plaintext handler.
        _ = channel.setOption(ChannelOptions.autoRead, value: false)

        // Strip all HTTP framing first, then send the CONNECT ack as RAW bytes:
        // routing it through HTTPResponseEncoder would chunk-frame the bodyless 200
        // and inject `0\r\n\r\n` into the tunnel, corrupting the client's first TLS
        // record. Only then install the TLS terminator + fresh HTTP + capture stack.
        // An already-removed handler is fine to skip (`recover`), but the chain as a
        // whole must succeed before the ack: acking with the encoder still installed
        // would frame the tunnel bytes and corrupt the client's first TLS record.
        let removals = ["loom.http.decoder", "loom.http.encoder", "loom.proxy"].map { name in
            pipeline.removeHandler(name: name).recover { _ in () }
        }
        EventLoopFuture.andAllSucceed(removals, on: channel.eventLoop)
            .whenComplete { result in
                guard case .success = result else {
                    channel.close(promise: nil)
                    return
                }
                var ack = channel.allocator.buffer(capacity: 40)
                ack.writeString("HTTP/1.1 200 Connection Established\r\n\r\n")
                channel.writeAndFlush(ack).whenComplete { _ in
                    MITMPipeline.installTLS(
                        channel: channel, host: host, port: port, sslContext: sslContext,
                        store: store, forwarder: forwarder
                    )
                        .whenComplete { result in
                            switch result {
                            case .success:
                                _ = channel.setOption(ChannelOptions.autoRead, value: true)
                                channel.read()
                            case .failure:
                                channel.close(promise: nil)
                            }
                        }
                }
            }
    }

    // MARK: - CONNECT (blind HTTPS pass-through)

    private func openTunnel(context: ChannelHandlerContext, host: String, port: Int) {
        let clientChannel = context.channel
        let startedAt = Date()

        // Pin the upstream connection to the client channel's event loop so both
        // ends of the glued tunnel share one loop — `GlueHandler` relays by writing
        // to the partner's context, which NIO requires happen on that loop.
        ClientBootstrap(group: clientChannel.eventLoop)
            .connect(host: host, port: port)
            .whenComplete { result in
                switch result {
                case let .success(upstream):
                    if self.observeTunnels {
                        TunnelFlow.record(host: host, port: port, startedAt: startedAt, store: self.store)
                    }
                    self.spliceRawBytes(client: clientChannel, upstream: upstream)
                case .failure:
                    clientChannel.close(promise: nil)
                }
            }
    }

    private func spliceRawBytes(client: Channel, upstream: Channel) {
        // Strip HTTP framing, glue the raw byte streams, then acknowledge the
        // CONNECT. The ack is written as raw bytes (not via HTTPResponseEncoder):
        // the encoder would chunk-frame a bodyless 200 and inject `0\r\n\r\n` into
        // the tunnel, corrupting the client's first TLS record.
        let removals = ["loom.http.encoder", "loom.http.decoder", "loom.proxy"].map { name in
            client.pipeline.removeHandler(name: name).recover { _ in () }
        }
        EventLoopFuture.andAllSucceed(removals, on: client.eventLoop).flatMap {
            TunnelFlow.glue(client: client, upstream: upstream)
        }.whenComplete { result in
            switch result {
            case .success:
                var ack = client.allocator.buffer(capacity: 40)
                ack.writeString("HTTP/1.1 200 Connection Established\r\n\r\n")
                client.writeAndFlush(ack, promise: nil)
            case .failure:
                client.close(promise: nil)
                upstream.close(promise: nil)
            }
        }
    }
}
