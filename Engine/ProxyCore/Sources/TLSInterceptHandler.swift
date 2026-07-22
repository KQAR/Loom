import Foundation
import NIOCore
import NIOHTTP1
import SharedModels

/// Runs on a client channel *after* TLS has been terminated with a minted leaf
/// certificate. It reads the now-decrypted HTTP requests, captures them, forwards
/// each to the real origin over a fresh (normally cert-validated) connection,
/// captures the response, and writes it back — all while the client believes it
/// is talking straight to the server. Keep-alive is honored: many requests may
/// share one intercepted connection.
final class TLSInterceptHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private let host: String
    private let port: Int
    private let store: FlowStore
    private let forwarder: UpstreamForwarding

    private var requestHead: HTTPRequestHead?
    private var bodyBuffer: ByteBuffer?

    init(host: String, port: Int, store: FlowStore, forwarder: UpstreamForwarding) {
        self.host = host
        self.port = port
        self.store = store
        self.forwarder = forwarder
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case let .head(head):
            requestHead = head
            bodyBuffer = context.channel.allocator.buffer(capacity: 0)
        case var .body(chunk):
            bodyBuffer?.writeBuffer(&chunk)
        case .end:
            guard let head = requestHead else { return }
            let body = bodyBuffer.flatMap { buf in
                buf.getBytes(at: buf.readerIndex, length: buf.readableBytes).map { Data($0) }
            }
            handle(channel: context.channel, head: head, body: body)
            requestHead = nil
            bodyBuffer = nil
        }
    }

    private func handle(channel: Channel, head: HTTPRequestHead, body: Data?) {
        let absolute = absoluteURLString(for: head)
        guard let url = URL(string: absolute) else {
            HTTPUtil.writeResponse(channel: channel, status: 400, headers: [],
                                   body: Data("Loom: bad intercepted URI\n".utf8), keepAlive: false)
            return
        }

        let headers = HTTPUtil.headerPairs(head.headers)
        let capturedRequest = CapturedRequest(method: head.method.rawValue, url: absolute, headers: headers, body: body)
        let flowID = UUID()
        let startedAt = Date()
        let store = self.store
        let forwarder = self.forwarder
        let keepAlive = head.isKeepAlive
        let method = head.method.rawValue
        let sourcePort = channel.remoteAddress?.port
        let proxyPort = channel.localAddress?.port

        // WebSocket over TLS (wss): splice the decrypted stream and originate a
        // fresh TLS connection upstream, capturing frames. Keep the client's TLS
        // handler in place; strip only the HTTP framing + this handler.
        if WebSocketRelay.isUpgrade(head) {
            let sourceApp = ProcessResolver.resolve(sourcePort: sourcePort, proxyPort: proxyPort)
            let requestPath = head.uri.hasPrefix("/") ? head.uri : "/\(head.uri)"
            WebSocketRelay.start(
                clientChannel: channel, head: head, requestPath: requestPath, host: host,
                port: port, upstreamTLS: true,
                removeHandlerNames: ["loom.mitm.encoder", "loom.mitm.decoder", "loom.mitm.intercept"],
                flowID: flowID, request: capturedRequest, startedAt: startedAt, sourceApp: sourceApp, store: store
            )
            return
        }

        Task {
            let sourceApp = ProcessResolver.resolve(sourcePort: sourcePort, proxyPort: proxyPort)
            await store.upsert(Flow(id: flowID, request: capturedRequest, startedAt: startedAt, sourceApp: sourceApp))
            await StreamRelay.relay(
                stream: forwarder.forwardStream(method: method, url: url, headers: headers, body: body),
                channel: channel, keepAlive: keepAlive, flowID: flowID,
                request: capturedRequest, startedAt: startedAt, sourceApp: sourceApp, store: store
            )
        }
    }

    /// Intercepted requests arrive in origin form (`/path`); rebuild the absolute
    /// URL from the CONNECT authority so the captured flow and the upstream fetch
    /// both address the real host.
    private func absoluteURLString(for head: HTTPRequestHead) -> String {
        let lower = head.uri.lowercased()
        if lower.hasPrefix("https://") || lower.hasPrefix("http://") { return head.uri }
        let authority = port == 443 ? host : "\(host):\(port)"
        let path = head.uri.hasPrefix("/") ? head.uri : "/\(head.uri)"
        return "https://\(authority)\(path)"
    }
}
