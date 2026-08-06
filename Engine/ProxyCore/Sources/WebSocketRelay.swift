import Foundation
import NIOCore
import NIOPosix
import NIOHTTP1
import NIOSSL
import LoomSharedModels

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
        sourceApp: SourceApp?, sourceDevice: SourceDevice?,
        store: FlowStore
    ) {
        // Pause client reads until both pipelines are reconfigured, so frames
        // can't reach a half-removed pipeline.
        _ = clientChannel.setOption(ChannelOptions.autoRead, value: false)

        ClientBootstrap(group: clientChannel.eventLoop)
            .channelInitializer { channel in
                // Built inside the (non-`@Sendable`) `makeCompletedFuture` body rather
                // than hoisted above the bootstrap: `NIOSSLClientHandler` is not
                // `Sendable`, so a hoisted one crossed into the `@Sendable`
                // initializer. Semantics are unchanged, `try?` included — a handler
                // that won't build still means a plaintext connection to a `wss://`
                // upstream, which is a separate question from this one.
                channel.eventLoop.makeCompletedFuture {
                    guard upstreamTLS, let sslHandler = try? Self.makeSSLHandler(host: host) else { return }
                    try channel.pipeline.syncOperations.addHandler(sslHandler)
                }
            }
            .connect(host: host, port: port)
            .whenComplete { result in
                switch result {
                case let .success(upstream):
                    setup(client: clientChannel, upstream: upstream, head: head, requestPath: requestPath,
                          removeHandlerNames: removeHandlerNames, flowID: flowID, request: request,
                          startedAt: startedAt, sourceApp: sourceApp, sourceDevice: sourceDevice, store: store)
                case .failure:
                    HTTPUtil.writeResponse(channel: clientChannel, status: 502, headers: [],
                                           body: Data("Loom: WebSocket upstream unreachable\n".utf8), keepAlive: false)
                }
            }
    }

    private static func setup(
        client: Channel, upstream: Channel, head: HTTPRequestHead, requestPath: String,
        removeHandlerNames: [String], flowID: UUID, request: CapturedRequest,
        startedAt: Date, sourceApp: SourceApp?, sourceDevice: SourceDevice?, store: FlowStore
    ) {
        let sink = WebSocketCaptureSink(
            flowID: flowID, request: request, startedAt: startedAt, sourceApp: sourceApp, sourceDevice: sourceDevice,
            eventLoop: client.eventLoop, store: store
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
                    upstream.writeAndFlush(buffer, promise: nil)

                    let started = Flow(
                        id: flowID, request: request, startedAt: startedAt,
                        outcome: .streaming(CapturedResponse(statusCode: 101, headers: [], body: nil)),
                        sourceApp: sourceApp, sourceDevice: sourceDevice, webSocketMessages: []
                    )
                    Task { await store.upsert(started, force: true) }

                    _ = client.setOption(ChannelOptions.autoRead, value: true)
                    client.read()
                case .failure:
                    // Neither tap made it into a pipeline, so no `channelInactive`
                    // will ever arrive to call `finish()` — end the capture here or
                    // the sink's consumer task parks forever. Nothing is published:
                    // this socket never relayed a byte.
                    sink.abandon()
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
///
/// Upserts are also **coalesced**: recording a frame schedules one trailing flush
/// on the shared event loop rather than upserting per frame. A 1000-frame/s socket
/// used to mean 1000 `FlowStore` actor hops a second — serialized against every
/// other capture and every UI/MCP read — to publish snapshots no reader could tell
/// apart. Same window as `FlowPersistence`'s write batching and `AppFeature`'s
/// stream batching, for the same reason.
final class WebSocketCaptureSink: @unchecked Sendable {
    static let maxMessages = 10_000
    static let maxCapturedBytes = 5_000_000
    /// Trailing-flush window for coalesced frame upserts.
    static let coalesceWindow = TimeAmount.milliseconds(100)

    private let flowID: UUID
    private let request: CapturedRequest
    private let startedAt: Date
    private let sourceApp: SourceApp?
    private let sourceDevice: SourceDevice?
    private var messages: [WebSocketMessage] = []
    private var capturedBytes = 0
    private var capped = false
    /// Frames seen after the cap tripped — recorded as a count on the flow so the
    /// transcript is honestly labelled partial.
    private var dropped = 0
    private var finished = false
    private let continuation: AsyncStream<Flow>.Continuation
    /// Client and upstream share one loop, so scheduled flushes land on the same
    /// thread as `record` — the message list still needs no locking.
    private let eventLoop: EventLoop
    private var flushScheduled = false

    init(flowID: UUID, request: CapturedRequest, startedAt: Date, sourceApp: SourceApp?, sourceDevice: SourceDevice?, eventLoop: EventLoop, store: FlowStore) {
        self.flowID = flowID
        self.request = request
        self.startedAt = startedAt
        self.sourceApp = sourceApp
        self.sourceDevice = sourceDevice
        self.eventLoop = eventLoop

        let (stream, continuation) = AsyncStream.makeStream(of: Flow.self)
        self.continuation = continuation
        Task { for await flow in stream { await store.upsert(flow, force: true) } }
    }

    /// Backstop for the consumer task, which is unstored and ends only when the
    /// stream does. Without this, any path that drops the sink without calling
    /// `finish()`/`abandon()` leaves that task parked on `for await` forever,
    /// holding the sink's frames and a live `FlowStore` reference for the life of
    /// the process. Finishing an already-finished continuation is a no-op.
    deinit { continuation.finish() }

    func record(direction: WebSocketMessage.Direction, frame: WebSocketFrameParser.Frame) {
        if capped {
            // The relay still forwards the bytes; we just stop recording — but we
            // count what we dropped so a reader can tell a complete frame log from a
            // partial one. No upsert per dropped frame: that would reintroduce the
            // per-frame store churn the cap exists to stop. The count rides the
            // `finish()` upsert (and the first-drop one below).
            dropped += 1
            return
        }
        if messages.count >= Self.maxMessages || capturedBytes >= Self.maxCapturedBytes {
            capped = true
            dropped += 1
            Log.ws.notice("WebSocket capture cap reached for flow \(self.flowID, privacy: .public); further frames not recorded.")
            enqueue(completed: false) // once, so the UI shows "capped" without waiting for close
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
        scheduleFlush()
    }

    func finish() {
        guard !finished else { return }
        finished = true
        // Unconditional, not coalesced: this is the snapshot that completes the
        // flow, and a pending trailing flush would be dropped by the guard below.
        enqueue(completed: true)
        continuation.finish()
    }

    /// End the capture without publishing anything — for the paths where the relay
    /// never started, so there is no exchange to record. `finish()` would upsert a
    /// completed WebSocket flow for a socket that never carried a frame.
    func abandon() {
        guard !finished else { return }
        finished = true
        continuation.finish()
    }

    /// Publish the accumulated frames once per window. Re-entrant calls within the
    /// window are free — the flush already pending will pick up everything recorded
    /// since, because `enqueue` snapshots the list at fire time.
    private func scheduleFlush() {
        guard !flushScheduled else { return }
        flushScheduled = true
        eventLoop.scheduleTask(in: Self.coalesceWindow) { [weak self] in
            guard let self else { return }
            self.flushScheduled = false
            guard !self.finished else { return }
            self.enqueue(completed: false)
        }
    }

    private func enqueue(completed: Bool) {
        let response = CapturedResponse(statusCode: 101, headers: [], body: nil)
        continuation.yield(Flow(
            id: flowID, request: request, startedAt: startedAt,
            outcome: completed ? .completed(response, at: Date()) : .streaming(response),
            sourceApp: sourceApp, sourceDevice: sourceDevice, webSocketMessages: messages,
            webSocketDroppedMessages: dropped > 0 ? dropped : nil
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
// @unchecked Sendable: event-loop confined, no lock — see ProxyCore/CLAUDE.md
// § Sendable escape hatches for what that forbids inside a `Task {}`.
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
