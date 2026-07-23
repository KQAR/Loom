import Foundation
import NIOCore
import NIOPosix
import NIOHTTP1
import NIOSSL
import SharedModels

/// Splices a WebSocket connection client↔upstream, relaying the post-upgrade
/// bytes verbatim (never re-encoded) while tapping a copy of each direction
/// through `WebSocketFrameParser` for capture. Keeps the exchange as one `Flow`
/// whose `webSocketMessages` grows as frames flow.
enum WebSocketRelay {
    /// A request is a WebSocket upgrade when it asks to switch to the `websocket`
    /// protocol (RFC 6455 §4.1).
    static func isUpgrade(_ head: HTTPRequestHead) -> Bool {
        let connection = head.headers["connection"].joined(separator: ",").lowercased()
        let upgrade = head.headers["upgrade"].first?.lowercased() ?? ""
        return connection.contains("upgrade") && upgrade == "websocket"
    }

    /// Begin relaying. `removeHandlerNames` are the client-pipeline handlers to
    /// strip so the channel deals in raw bytes (HTTP framing on the plain path,
    /// HTTP framing minus the TLS handler on the MITM path). `upstreamTLS` selects
    /// wss origination.
    static func start(
        clientChannel: Channel,
        head: HTTPRequestHead,
        requestPath: String,
        host: String,
        port: Int,
        upstreamTLS: Bool,
        removeHandlerNames: [String],
        flowID: UUID,
        request: CapturedRequest,
        startedAt: Date,
        sourceApp: SourceApp?,
        store: FlowStore
    ) {
        // Pause client reads until both pipelines are reconfigured, so frames
        // can't reach a half-removed pipeline.
        _ = clientChannel.setOption(ChannelOptions.autoRead, value: false)

        let sslHandler: NIOSSLClientHandler? = upstreamTLS ? try? Self.makeSSLHandler(host: host) : nil

        ClientBootstrap(group: clientChannel.eventLoop)
            .channelInitializer { channel in
                if let sslHandler {
                    return channel.pipeline.addHandler(sslHandler)
                }
                return channel.eventLoop.makeSucceededVoidFuture()
            }
            .connect(host: host, port: port)
            .whenComplete { result in
                switch result {
                case let .success(upstream):
                    setup(client: clientChannel, upstream: upstream, head: head, requestPath: requestPath,
                          removeHandlerNames: removeHandlerNames, flowID: flowID, request: request,
                          startedAt: startedAt, sourceApp: sourceApp, store: store)
                case .failure:
                    HTTPUtil.writeResponse(channel: clientChannel, status: 502, headers: [],
                                           body: Data("Loom: WebSocket upstream unreachable\n".utf8), keepAlive: false)
                }
            }
    }

    private static func setup(
        client: Channel, upstream: Channel, head: HTTPRequestHead, requestPath: String,
        removeHandlerNames: [String], flowID: UUID, request: CapturedRequest,
        startedAt: Date, sourceApp: SourceApp?, store: FlowStore
    ) {
        let sink = WebSocketCaptureSink(
            flowID: flowID, request: request, startedAt: startedAt, sourceApp: sourceApp, store: store
        )
        // Client→server bytes start with frames (the GET was already consumed);
        // server→client bytes start with the 101 handshake, which the tap skips.
        let clientTap = WebSocketTapHandler(direction: .clientToServer, expectsHandshake: false, sink: sink)
        let upstreamTap = WebSocketTapHandler(direction: .serverToClient, expectsHandshake: true, sink: sink)
        clientTap.partner = upstreamTap
        upstreamTap.partner = clientTap

        // A failed removal must NOT be swallowed: a leftover HTTP-typed handler
        // would force-unwrap the raw post-upgrade bytes and crash. Let the
        // failure fall through to the close-both-channels branch below.
        let removals = removeHandlerNames.map { name in
            client.pipeline.removeHandler(name: name)
        }
        EventLoopFuture.andAllSucceed(removals, on: client.eventLoop)
            .flatMap { client.pipeline.addHandler(clientTap) }
            .flatMap { upstream.pipeline.addHandler(upstreamTap) }
            .whenComplete { outcome in
                switch outcome {
                case .success:
                    // Replay the upgrade request to the origin; its 101 + frames
                    // flow back through the taps to the client.
                    var buffer = upstream.allocator.buffer(capacity: 256)
                    buffer.writeString(serializeUpgrade(head, path: requestPath))
                    upstream.writeAndFlush(NIOAny(buffer), promise: nil)

                    let started = Flow(
                        id: flowID, request: request, startedAt: startedAt,
                        outcome: .streaming(CapturedResponse(statusCode: 101, headers: [], body: nil)),
                        sourceApp: sourceApp, webSocketMessages: []
                    )
                    Task { await store.upsert(started, force: true) }

                    _ = client.setOption(ChannelOptions.autoRead, value: true)
                    client.read()
                case .failure:
                    client.close(promise: nil)
                    upstream.close(promise: nil)
                }
            }
    }

    /// Re-serialize the upgrade request in origin form for the upstream leg,
    /// preserving the WebSocket handshake headers (Sec-WebSocket-Key etc.).
    static func serializeUpgrade(_ head: HTTPRequestHead, path: String) -> String {
        var lines = ["\(head.method.rawValue) \(path) HTTP/1.1"]
        for header in head.headers {
            let lower = header.name.lowercased()
            if lower == "proxy-connection" { continue } // proxy hop artifact
            lines.append("\(header.name): \(header.value)")
        }
        return lines.joined(separator: "\r\n") + "\r\n\r\n"
    }

    private static func makeSSLHandler(host: String) throws -> NIOSSLClientHandler {
        try NIOSSLClientHandler(context: SharedTLS.clientContext, serverHostname: host)
    }
}

// MARK: - Capture

/// Accumulates captured frames for one WebSocket flow and re-upserts it. Only
/// touched on the shared event loop (client + upstream share one loop), so the
/// message list needs no locking.
///
/// Upserts are funneled through a single long-lived consumer task reading an
/// `AsyncStream`, so they land in the order produced. The previous design fired
/// one unstructured `Task` per frame, which had no ordering guarantee: a stale
/// per-frame snapshot could land after `finish()`, leaving the flow permanently
/// un-completed. Captured messages are also capped so a chatty socket can't grow
/// the store without bound (the relay still forwards every byte; only the
/// recorded copy stops).
final class WebSocketCaptureSink: @unchecked Sendable {
    static let maxMessages = 10_000
    static let maxCapturedBytes = 5_000_000

    private let flowID: UUID
    private let request: CapturedRequest
    private let startedAt: Date
    private let sourceApp: SourceApp?
    private var messages: [WebSocketMessage] = []
    private var capturedBytes = 0
    private var capped = false
    private var finished = false
    private let continuation: AsyncStream<Flow>.Continuation

    init(flowID: UUID, request: CapturedRequest, startedAt: Date, sourceApp: SourceApp?, store: FlowStore) {
        self.flowID = flowID
        self.request = request
        self.startedAt = startedAt
        self.sourceApp = sourceApp

        let (stream, continuation) = AsyncStream.makeStream(of: Flow.self)
        self.continuation = continuation
        Task { for await flow in stream { await store.upsert(flow, force: true) } }
    }

    func record(direction: WebSocketMessage.Direction, frame: WebSocketFrameParser.Frame) {
        if capped { return } // relay still forwards the bytes; we just stop recording
        if messages.count >= Self.maxMessages || capturedBytes >= Self.maxCapturedBytes {
            capped = true
            Log.ws.notice("WebSocket capture cap reached for flow \(self.flowID, privacy: .public); further frames not recorded.")
            return
        }
        messages.append(WebSocketMessage(
            direction: direction,
            kind: WebSocketMessage.Kind(opcode: frame.opcode),
            payload: frame.payload,
            isFinal: frame.isFinal,
            timestamp: Date()
        ))
        capturedBytes += frame.payload.count
        enqueue(completed: false)
    }

    func finish() {
        guard !finished else { return }
        finished = true
        enqueue(completed: true)
        continuation.finish()
    }

    private func enqueue(completed: Bool) {
        let response = CapturedResponse(statusCode: 101, headers: [], body: nil)
        continuation.yield(Flow(
            id: flowID, request: request, startedAt: startedAt,
            outcome: completed ? .completed(response, at: Date()) : .streaming(response),
            sourceApp: sourceApp, webSocketMessages: messages
        ))
    }
}

/// Skips the HTTP handshake preamble on a direction, then parses everything after
/// as WebSocket frames. Pure/testable — the channel handler is thin plumbing.
struct WebSocketStreamTap {
    private var parser = WebSocketFrameParser()
    private var handshakeDone: Bool
    private var pending: [UInt8] = []

    init(expectsHandshake: Bool) {
        handshakeDone = !expectsHandshake
    }

    mutating func consume(_ bytes: [UInt8]) -> [WebSocketFrameParser.Frame] {
        if handshakeDone {
            return parser.feed(bytes)
        }
        pending.append(contentsOf: bytes)
        guard let bodyStart = Self.endOfHeaders(pending) else { return [] }
        handshakeDone = true
        let rest = Array(pending[bodyStart...])
        pending = []
        return parser.feed(rest)
    }

    /// Index just past the `\r\n\r\n` that ends the HTTP handshake, or nil.
    private static func endOfHeaders(_ bytes: [UInt8]) -> Int? {
        guard bytes.count >= 4 else { return nil }
        for i in 0 ... (bytes.count - 4) where bytes[i] == 0x0D && bytes[i + 1] == 0x0A && bytes[i + 2] == 0x0D && bytes[i + 3] == 0x0A {
            return i + 4
        }
        return nil
    }
}

/// Byte-transparent relay for one side of a spliced WebSocket, tapping inbound
/// bytes for capture. Modeled on `GlueHandler`.
final class WebSocketTapHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    var partner: WebSocketTapHandler?
    private var context: ChannelHandlerContext?
    private let direction: WebSocketMessage.Direction
    private let sink: WebSocketCaptureSink
    private var tap: WebSocketStreamTap

    init(direction: WebSocketMessage.Direction, expectsHandshake: Bool, sink: WebSocketCaptureSink) {
        self.direction = direction
        self.sink = sink
        self.tap = WebSocketStreamTap(expectsHandshake: expectsHandshake)
    }

    func handlerAdded(context: ChannelHandlerContext) {
        self.context = context
    }

    func handlerRemoved(context: ChannelHandlerContext) {
        self.context = nil
        partner = nil
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let buffer = unwrapInboundIn(data)
        partner?.relayWrite(buffer)
        if let bytes = buffer.getBytes(at: buffer.readerIndex, length: buffer.readableBytes) {
            for frame in tap.consume(bytes) {
                sink.record(direction: direction, frame: frame)
            }
        }
    }

    func channelReadComplete(context: ChannelHandlerContext) {
        partner?.relayFlush()
    }

    func channelInactive(context: ChannelHandlerContext) {
        partner?.relayClose()
        sink.finish()
    }

    private func relayWrite(_ buffer: ByteBuffer) {
        context?.write(NIOAny(buffer), promise: nil)
    }

    private func relayFlush() {
        context?.flush()
    }

    private func relayClose() {
        context?.close(promise: nil)
    }
}
