import Foundation
import NIOCore
import NIOHTTP1
import LoomSharedModels

/// Runs on a client channel *after* TLS has been terminated with a minted leaf
/// certificate. It reads the now-decrypted HTTP requests, captures them, forwards
/// each to the real origin over a fresh (normally cert-validated) connection,
/// captures the response, and writes it back — all while the client believes it
/// is talking straight to the server. Keep-alive is honored: many requests may
/// share one intercepted connection.
///
/// Also serves cleartext HTTP whose destination came from somewhere other than the
/// request line (`upstreamTLS: false`, used by the SOCKS listener): the shape is
/// identical — origin-form requests plus a known host:port — and the only
/// difference is which scheme the rebuilt absolute URL carries.
// @unchecked Sendable: event-loop confined, no lock — see ProxyCore/CLAUDE.md
// § Sendable escape hatches for what that forbids inside a `Task {}`.
final class TLSInterceptHandler: ChannelInboundHandler, RemovableChannelHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private let host: String
    private let port: Int
    private let store: FlowStore
    private let forwarder: UpstreamForwarding
    /// Whether the leg Loom re-originates is TLS. True for a MITM'd CONNECT (the
    /// client believes it is on HTTPS); false for cleartext HTTP arriving over
    /// SOCKS, where re-fetching over `https://` would be a different request.
    private let upstreamTLS: Bool
    /// What the client negotiated on the way in. Supplied by `MITMPipeline`,
    /// which is the only place that knows it: ALPN decides the HTTP version (an
    /// h2 request reaches this handler as an HTTP/1.1 head, built by the h2↔h1
    /// codec), and the TLS handler that knows the version lives on the *parent*
    /// of an h2 stream channel. Nil means "derive it from the head", which is
    /// right for every plaintext path and wrong for both of those.
    private let negotiatedProtocol: String?
    private let clientTLSVersion: String?
    /// Whether this leg is HTTP/1.1 only because Loom withheld ALPN `h2` from the
    /// host. Stated by the entry point for the same reason `negotiatedProtocol` is:
    /// once the request is in hand a downgraded leg is indistinguishable from a
    /// genuine h1 client, and the difference is what an operator is measuring.
    private let clientProtocolDowngraded: Bool

    private var requestHead: HTTPRequestHead?
    private var requestURL: URL?
    private var requestAbsolute: String?
    /// The flow recorded when this request's head arrived. Nil between exchanges.
    private var observed: CapturedExchange.Observed?
    /// Live bridge for the current request's streamed body — created lazily on the
    /// first body chunk, so an h2 DATA body with no Content-Length still streams
    /// (h2 frames the body without h1 framing headers).
    private var bodyBridge: RequestBodyBridge?
    private var droppingRequest = false

    init(
        host: String, port: Int, store: FlowStore, forwarder: UpstreamForwarding,
        upstreamTLS: Bool = true, negotiatedProtocol: String? = nil, clientTLSVersion: String? = nil,
        clientProtocolDowngraded: Bool = false
    ) {
        self.host = host
        self.port = port
        self.store = store
        self.forwarder = forwarder
        self.upstreamTLS = upstreamTLS
        self.negotiatedProtocol = negotiatedProtocol
        self.clientTLSVersion = clientTLSVersion
        self.clientProtocolDowngraded = clientProtocolDowngraded
    }

    private func clientLeg(for head: HTTPRequestHead) -> CapturedExchange.ClientLeg {
        CapturedExchange.ClientLeg(
            httpVersion: negotiatedProtocol ?? HTTPUtil.clientProtocol(head.version),
            tlsVersion: clientTLSVersion,
            downgraded: clientProtocolDowngraded
        )
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case var .head(head):
            // An h2 client splits `cookie` into crumbs; upstream is HTTP/1.1, which
            // takes exactly one. See `HTTPUtil.coalesceCookieCrumbs`.
            head.headers = HTTPUtil.coalesceCookieCrumbs(head.headers)
            let absolute = absoluteURLString(for: head)
            guard let url = URL(string: absolute) else {
                HTTPUtil.writeResponse(channel: context.channel, status: 400, headers: [],
                                       body: Data("Loom: bad intercepted URI\n".utf8), keepAlive: false)
                droppingRequest = true
                return
            }
            requestHead = head
            requestURL = url
            requestAbsolute = absolute
            // Recorded here, not at `.end`: a request that stalls after its head is
            // still a request, and used to leave no trace at all.
            observed = CapturedExchange.observe(
                channel: context.channel, head: head, urlString: absolute, store: store,
                clientLeg: clientLeg(for: head)
            )
        case var .body(chunk):
            if droppingRequest { return }
            if bodyBridge == nil {
                guard let head = requestHead, let url = requestURL, let absolute = requestAbsolute else { return }
                let bridge = RequestBodyBridge(capture: RequestBodyCapture())
                bridge.attach(channel: context.channel)
                bodyBridge = bridge
                _ = context.channel.setOption(ChannelOptions.autoRead, value: false)
                startExchange(channel: context.channel, head: head, url: url, absolute: absolute,
                              body: .stream(bridge.chunks,
                                            contentLength: RequestBodyStreaming.contentLength(head),
                                            trailers: bridge.trailers),
                              capture: bridge.capture)
            }
            if let bytes = chunk.readBytes(length: chunk.readableBytes) { bodyBridge?.yield(Data(bytes)) }
        case let .end(trailers):
            if let bodyBridge {
                bodyBridge.finish(trailers: trailers.map(HTTPUtil.headerPairs))
                self.bodyBridge = nil
                _ = context.channel.setOption(ChannelOptions.autoRead, value: true) // resume for keep-alive
                resetRequest()
                return
            }
            if droppingRequest { droppingRequest = false; resetRequest(); return }
            guard let head = requestHead, let url = requestURL, let absolute = requestAbsolute else { return }
            // A bodyless request with a trailer section is not a shape any client
            // sends, but carrying it costs nothing and dropping it would be one more
            // silent edit.
            startExchange(channel: context.channel, head: head, url: url, absolute: absolute,
                          body: .bytes(nil, trailers: trailers.map(HTTPUtil.headerPairs)), capture: nil)
            resetRequest()
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
        resetRequest()
        bridge.abort(reason: reason)
    }

    private func resetRequest() {
        requestHead = nil; requestURL = nil; requestAbsolute = nil; observed = nil
    }

    private func startExchange(channel: Channel, head: HTTPRequestHead, url: URL, absolute: String, body: RequestBody, capture: RequestBodyCapture?) {
        let observed = self.observed ?? CapturedExchange.observe(
            channel: channel, head: head, urlString: absolute, store: store,
            clientLeg: clientLeg(for: head)
        )
        // wss: keep the client's TLS handler in place, strip only the HTTP framing
        // + this handler; the upstream leg re-originates TLS.
        let requestPath = head.uri.hasPrefix("/") ? head.uri : "/\(head.uri)"
        CapturedExchange.handle(
            channel: channel, head: head, body: body, bodyCapture: capture,
            routing: CapturedExchange.Routing(
                url: url,
                urlString: absolute,
                webSocketHost: host,
                webSocketPort: port,
                webSocketUpstreamTLS: upstreamTLS,
                webSocketRequestPath: requestPath,
                webSocketRemoveHandlerNames: [
                    MITMPipeline.encoderName, MITMPipeline.decoderName, MITMPipeline.interceptName,
                ]
            ),
            store: store, forwarder: forwarder, observed: observed, clientLeg: clientLeg(for: head)
        )
    }

    /// Intercepted requests arrive in origin form (`/path`); rebuild the absolute
    /// URL from the known authority so the captured flow and the upstream fetch
    /// both address the real host. The scheme's default port is elided so the
    /// captured URL reads the way the client wrote it.
    private func absoluteURLString(for head: HTTPRequestHead) -> String {
        let lower = head.uri.lowercased()
        if lower.hasPrefix("https://") || lower.hasPrefix("http://") { return head.uri }
        let scheme = upstreamTLS ? "https" : "http"
        let defaultPort = upstreamTLS ? 443 : 80
        let authority = port == defaultPort ? host : "\(host):\(port)"
        let path = head.uri.hasPrefix("/") ? head.uri : "/\(head.uri)"
        return "\(scheme)://\(authority)\(path)"
    }
}
