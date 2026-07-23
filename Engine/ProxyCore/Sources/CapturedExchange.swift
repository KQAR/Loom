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
        body: RequestBody,
        bodyCapture: RequestBodyCapture?,
        routing: Routing,
        store: FlowStore,
        forwarder: UpstreamForwarding
    ) {
        let headers = HTTPUtil.headerPairs(head.headers)
        // For a streamed body the bytes aren't known yet; `bodyCapture` fills them in
        // as they flow, and `StreamRelay` reads the complete copy on the response
        // upserts (the request finishes before the response head by HTTP ordering).
        let initialBody: Data?
        switch body {
        case let .bytes(data): initialBody = data
        case .stream: initialBody = nil
        }
        let capturedRequest = CapturedRequest(
            method: head.method.rawValue, url: routing.urlString, headers: headers, body: initialBody
        )
        let flowID = UUID()
        let startedAt = Date()
        let keepAlive = head.isKeepAlive
        let method = head.method.rawValue
        let sourcePort = channel.remoteAddress?.port
        let proxyPort = channel.localAddress?.port
        // Device attribution (remote IP + UA type) is pure and loop-safe, unlike
        // the libproc `sourceApp` scan below — compute it here and capture it.
        let sourceDevice = device(channel: channel, headers: headers)

        // A WebSocket upgrade is spliced (frames captured) rather than fetched.
        if WebSocketRelay.isUpgrade(head) {
            // Pause client reads *now* (we're on the event loop) so frames can't
            // reach a half-removed pipeline while we resolve the source app — that
            // resolution is a blocking libproc scan that must run off the loop, so
            // it happens in a Task before hopping back to start the splice.
            _ = channel.setOption(ChannelOptions.autoRead, value: false)
            let eventLoop = channel.eventLoop
            Task {
                let sourceApp = ProcessResolver.resolve(sourcePort: sourcePort, proxyPort: proxyPort)
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
            let sourceApp = ProcessResolver.resolve(sourcePort: sourcePort, proxyPort: proxyPort)
            await store.upsert(Flow(id: flowID, request: capturedRequest, startedAt: startedAt, sourceApp: sourceApp, sourceDevice: sourceDevice))
            await StreamRelay.relay(
                stream: forwarder.forwardStream(method: method, url: routing.url, headers: headers, body: body),
                channel: channel, keepAlive: keepAlive, flowID: flowID,
                request: capturedRequest, startedAt: startedAt, sourceApp: sourceApp, sourceDevice: sourceDevice,
                store: store, bodyCapture: bodyCapture
            )
        }
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
