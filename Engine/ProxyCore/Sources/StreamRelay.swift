import Foundation
import NIOCore
import LoomSharedModels

/// Consumes an upstream response stream, relaying it to the client channel
/// chunk-by-chunk while capturing the exchange as a `Flow`. Shared by the plain
/// HTTP and MITM paths so both stream identically.
enum StreamRelay {
    /// Bound the captured body so an endless stream (SSE) can't grow the store
    /// without limit — the client still receives every byte; only the recorded
    /// copy is capped.
    static let captureCap = 5_000_000

    static func relay(
        stream: AsyncThrowingStream<UpstreamResponseEvent, Error>,
        channel: Channel,
        keepAlive: Bool,
        flowID: UUID,
        request: CapturedRequest,
        startedAt: Date,
        sourceApp: SourceApp?,
        sourceDevice: SourceDevice?,
        store: FlowStore,
        bodyCapture: RequestBodyCapture? = nil,
        /// The client's trailer section, readable once its body stream has ended —
        /// the request-side sibling of `bodyCapture`, and backfilled at the same
        /// points for the same reason.
        requestTrailers: RequestTrailers? = nil,
        /// What the *client* leg already contributed (its TLS version) — the
        /// upstream events only ever describe Loom's own hop, and a failure
        /// before any head would otherwise lose the client half entirely.
        clientTransport: FlowTransport? = nil,
        captureCap: Int = StreamRelay.captureCap
    ) async {
        // If the client disconnects mid-stream (closed SSE tab, aborted download),
        // cancel consumption so the stream's onTermination cancels the upstream
        // connection — otherwise Loom holds an open upstream socket forever,
        // writing into a dead channel. Run the relay in a child task the
        // client's closeFuture can cancel.
        let work = Task { await relayInner(
            stream: stream, channel: channel, keepAlive: keepAlive, flowID: flowID,
            request: request, startedAt: startedAt, sourceApp: sourceApp, sourceDevice: sourceDevice,
            store: store, bodyCapture: bodyCapture, requestTrailers: requestTrailers,
            clientTransport: clientTransport, captureCap: captureCap
        ) }
        channel.closeFuture.whenComplete { _ in work.cancel() }
        await work.value
    }

    private static func relayInner(
        stream: AsyncThrowingStream<UpstreamResponseEvent, Error>,
        channel: Channel,
        keepAlive: Bool,
        flowID: UUID,
        request baseRequest: CapturedRequest,
        startedAt: Date,
        sourceApp: SourceApp?,
        sourceDevice: SourceDevice?,
        store: FlowStore,
        bodyCapture: RequestBodyCapture?,
        requestTrailers: RequestTrailers?,
        clientTransport: FlowTransport?,
        captureCap: Int
    ) async {
        // For a streamed request body, fold the (by-now complete) captured copy into
        // the request recorded on the flow. `baseRequest.body` is nil while streaming;
        // this backfills it once the body has flowed.
        func request() -> CapturedRequest {
            var request = baseRequest
            // The client's trailer section is only knowable once its body has
            // finished, so — like the body itself — it is read here rather than
            // stamped when the exchange started.
            if let sent = requestTrailers?.current { request.trailers = sent }
            guard let bodyCapture else { return request }
            let snapshot = bodyCapture.snapshot()
            request.body = snapshot.body
            request.fullBodyBytes = snapshot.fullBodyBytes
            return request
        }
        var statusCode = 0
        /// When the response head landed — the TTFB split point (server think-time
        /// vs body transfer). Nil until a head arrives, so a pre-head failure has no
        /// TTFB rather than a fabricated one.
        var firstByteAt: Date?
        var httpVersion: String?
        var responseHeaders: [HeaderPair] = []
        var appliedRules: [AppliedRule] = []
        /// How the exchange travelled, folded from the (at most two) `.transport`
        /// instalments — see `UpstreamResponseEvent.transport` for why it arrives
        /// in pieces. Nil for a response that never reached a socket, which is a
        /// different answer from one whose fields are all nil.
        var transport: FlowTransport? = clientTransport
        var capturedBody = Data()
        /// Every response byte relayed, cap included — so a truncated capture can
        /// report the true size rather than looking like a body that ended at the cap.
        var wireBodyBytes = 0
        var headWritten = false
        var bodyless = false
        /// The origin's trailer section, arriving with the terminal event. Kept as a
        /// separate `var` rather than folded into `responseHeaders`: a trailer is
        /// not a header, and merging them would make a `grpc-status` that arrived
        /// after the body indistinguishable from one the origin promised up front.
        var responseTrailers: [HeaderPair]?

        /// The response as captured, flagged when `capturedBody` is only a prefix.
        func response(body: Data) -> CapturedResponse {
            CapturedResponse(
                statusCode: statusCode, httpVersion: httpVersion, headers: responseHeaders, body: body,
                fullBodyBytes: wireBodyBytes > body.count ? wireBodyBytes : nil,
                trailers: responseTrailers
            )
        }

        do {
            for try await event in stream {
                // Client gone — stop relaying and let the loop's end tear down the
                // upstream stream (onTermination → upstream close).
                if Task.isCancelled || !channel.isActive { break }
                switch event {
                case let .metadata(rules):
                    // Rule hits arrive before the head (or before an upstream error), so
                    // record them now — this is what lets a *failed* exchange still show
                    // its applied rules in the flow / UI.
                    appliedRules = rules
                case let .transport(info):
                    transport = (transport ?? FlowTransport()).merging(info)
                case let .head(code, version, headers):
                    firstByteAt = Date()
                    statusCode = code
                    httpVersion = version
                    responseHeaders = headers
                    headWritten = true
                    bodyless = HTTPUtil.responseHasNoBody(requestMethod: baseRequest.method, status: code)
                    HTTPUtil.writeResponseHead(channel: channel, status: code, headers: headers, keepAlive: keepAlive, chunked: !bodyless)
                    // Surface the response status while the body is still streaming.
                    await store.upsert(Flow(
                        id: flowID, request: request(), startedAt: startedAt,
                        outcome: .streaming(CapturedResponse(statusCode: code, httpVersion: version, headers: headers, body: nil)),
                        firstByteAt: firstByteAt,
                        sourceApp: sourceApp, sourceDevice: sourceDevice,
                        appliedRules: appliedRules.isEmpty ? nil : appliedRules,
                        transport: transport
                    ))
                case let .body(chunk):
                    // A bodyless response (HEAD / 204 / 304) must never carry body
                    // bytes on the wire; still capture them for the inspector.
                    if !bodyless { HTTPUtil.writeResponseChunk(channel: channel, data: chunk) }
                    wireBodyBytes += chunk.count
                    if capturedBody.count < captureCap {
                        let remaining = captureCap - capturedBody.count
                        capturedBody.append(chunk.count <= remaining ? chunk : chunk.prefix(remaining))
                    }
                case let .end(trailers):
                    responseTrailers = trailers
                    HTTPUtil.finishResponse(channel: channel, keepAlive: keepAlive, trailers: trailers)
                }
            }
            await store.upsert(Flow(
                id: flowID, request: request(), startedAt: startedAt,
                outcome: .completed(response(body: capturedBody), at: Date()),
                firstByteAt: firstByteAt,
                sourceApp: sourceApp, sourceDevice: sourceDevice,
                appliedRules: appliedRules.isEmpty ? nil : appliedRules,
                transport: transport
            ))
        } catch {
            if headWritten {
                // Response already started; end it and record what we relayed + the error.
                HTTPUtil.finishResponse(channel: channel, keepAlive: false)
                await store.upsert(Flow(
                    id: flowID, request: request(), startedAt: startedAt,
                    outcome: .failed(
                        FlowError(error.localizedDescription), at: Date(),
                        partialResponse: response(body: capturedBody)
                    ),
                    firstByteAt: firstByteAt,
                    sourceApp: sourceApp, sourceDevice: sourceDevice,
                    appliedRules: appliedRules.isEmpty ? nil : appliedRules,
                    transport: transport
                ))
            } else {
                await store.upsert(Flow(
                    id: flowID, request: request(), startedAt: startedAt,
                    outcome: .failed(FlowError(error.localizedDescription), at: Date(), partialResponse: nil),
                    sourceApp: sourceApp, sourceDevice: sourceDevice,
                    appliedRules: appliedRules.isEmpty ? nil : appliedRules,
                    transport: transport
                ))
                HTTPUtil.writeResponse(
                    channel: channel, status: 502, headers: [],
                    body: Data("Loom upstream error: \(error.localizedDescription)\n".utf8), keepAlive: false
                )
            }
        }
    }
}
