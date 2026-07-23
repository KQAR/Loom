import Foundation
import NIOCore
import NIOHTTP1
import SharedModels

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

    static func handle(
        channel: Channel,
        head: HTTPRequestHead,
        body: Data?,
        routing: Routing,
        store: FlowStore,
        forwarder: UpstreamForwarding
    ) {
        let headers = HTTPUtil.headerPairs(head.headers)
        let capturedRequest = CapturedRequest(
            method: head.method.rawValue, url: routing.urlString, headers: headers, body: body
        )
        let flowID = UUID()
        let startedAt = Date()
        let keepAlive = head.isKeepAlive
        let method = head.method.rawValue
        let sourcePort = channel.remoteAddress?.port
        let proxyPort = channel.localAddress?.port

        // A WebSocket upgrade is spliced (frames captured) rather than fetched.
        if WebSocketRelay.isUpgrade(head) {
            let sourceApp = ProcessResolver.resolve(sourcePort: sourcePort, proxyPort: proxyPort)
            WebSocketRelay.start(
                clientChannel: channel, head: head, requestPath: routing.webSocketRequestPath,
                host: routing.webSocketHost, port: routing.webSocketPort,
                upstreamTLS: routing.webSocketUpstreamTLS,
                removeHandlerNames: routing.webSocketRemoveHandlerNames,
                flowID: flowID, request: capturedRequest, startedAt: startedAt, sourceApp: sourceApp, store: store
            )
            return
        }

        Task {
            let sourceApp = ProcessResolver.resolve(sourcePort: sourcePort, proxyPort: proxyPort)
            await store.upsert(Flow(id: flowID, request: capturedRequest, startedAt: startedAt, sourceApp: sourceApp))
            await StreamRelay.relay(
                stream: forwarder.forwardStream(method: method, url: routing.url, headers: headers, body: body),
                channel: channel, keepAlive: keepAlive, flowID: flowID,
                request: capturedRequest, startedAt: startedAt, sourceApp: sourceApp, store: store
            )
        }
    }
}
