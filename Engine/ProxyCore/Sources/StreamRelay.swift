import Foundation
import NIOCore
import SharedModels

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
        store: FlowStore
    ) async {
        // If the client disconnects mid-stream (closed SSE tab, aborted download),
        // cancel consumption so the stream's onTermination cancels the upstream
        // connection — otherwise Loom holds an open upstream socket forever,
        // writing into a dead channel. Run the relay in a child task the
        // client's closeFuture can cancel.
        let work = Task { await relayInner(
            stream: stream, channel: channel, keepAlive: keepAlive, flowID: flowID,
            request: request, startedAt: startedAt, sourceApp: sourceApp, store: store
        ) }
        channel.closeFuture.whenComplete { _ in work.cancel() }
        await work.value
    }

    private static func relayInner(
        stream: AsyncThrowingStream<UpstreamResponseEvent, Error>,
        channel: Channel,
        keepAlive: Bool,
        flowID: UUID,
        request: CapturedRequest,
        startedAt: Date,
        sourceApp: SourceApp?,
        store: FlowStore
    ) async {
        var statusCode = 0
        var httpVersion: String?
        var responseHeaders: [HeaderPair] = []
        var appliedRules: [AppliedRule] = []
        var capturedBody = Data()
        var headWritten = false
        var bodyless = false

        do {
            for try await event in stream {
                // Client gone — stop relaying and let the loop's end tear down the
                // upstream stream (onTermination → upstream close).
                if Task.isCancelled || !channel.isActive { break }
                switch event {
                case let .head(code, version, headers, rules):
                    statusCode = code
                    httpVersion = version
                    responseHeaders = headers
                    appliedRules = rules
                    headWritten = true
                    bodyless = HTTPUtil.responseHasNoBody(requestMethod: request.method, status: code)
                    HTTPUtil.writeResponseHead(channel: channel, status: code, headers: headers, keepAlive: keepAlive, chunked: !bodyless)
                    // Surface the response status while the body is still streaming.
                    await store.upsert(Flow(
                        id: flowID, request: request, startedAt: startedAt,
                        outcome: .streaming(CapturedResponse(statusCode: code, httpVersion: version, headers: headers, body: nil)),
                        sourceApp: sourceApp,
                        appliedRules: rules.isEmpty ? nil : rules
                    ))
                case let .body(chunk):
                    // A bodyless response (HEAD / 204 / 304) must never carry body
                    // bytes on the wire; still capture them for the inspector.
                    if !bodyless { HTTPUtil.writeResponseChunk(channel: channel, data: chunk) }
                    if capturedBody.count < captureCap {
                        let remaining = captureCap - capturedBody.count
                        capturedBody.append(chunk.count <= remaining ? chunk : chunk.prefix(remaining))
                    }
                case .end:
                    HTTPUtil.finishResponse(channel: channel, keepAlive: keepAlive)
                }
            }
            await store.upsert(Flow(
                id: flowID, request: request, startedAt: startedAt,
                outcome: .completed(
                    CapturedResponse(statusCode: statusCode, httpVersion: httpVersion, headers: responseHeaders, body: capturedBody),
                    at: Date()
                ),
                sourceApp: sourceApp,
                appliedRules: appliedRules.isEmpty ? nil : appliedRules
            ))
        } catch {
            if headWritten {
                // Response already started; end it and record what we relayed + the error.
                HTTPUtil.finishResponse(channel: channel, keepAlive: false)
                await store.upsert(Flow(
                    id: flowID, request: request, startedAt: startedAt,
                    outcome: .failed(
                        FlowError(error.localizedDescription), at: Date(),
                        partialResponse: CapturedResponse(statusCode: statusCode, httpVersion: httpVersion, headers: responseHeaders, body: capturedBody)
                    ),
                    sourceApp: sourceApp, appliedRules: appliedRules.isEmpty ? nil : appliedRules
                ))
            } else {
                await store.upsert(Flow(
                    id: flowID, request: request, startedAt: startedAt,
                    outcome: .failed(FlowError(error.localizedDescription), at: Date(), partialResponse: nil),
                    sourceApp: sourceApp
                ))
                HTTPUtil.writeResponse(
                    channel: channel, status: 502, headers: [],
                    body: Data("Loom upstream error: \(error.localizedDescription)\n".utf8), keepAlive: false
                )
            }
        }
    }
}
