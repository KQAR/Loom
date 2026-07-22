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
        var statusCode = 0
        var responseHeaders: [HeaderPair] = []
        var appliedRules: [String] = []
        var capturedBody = Data()
        var headWritten = false

        do {
            for try await event in stream {
                switch event {
                case let .head(code, headers, rules):
                    statusCode = code
                    responseHeaders = headers
                    appliedRules = rules
                    headWritten = true
                    HTTPUtil.writeResponseHead(channel: channel, status: code, headers: headers, keepAlive: keepAlive)
                    // Surface the response status while the body is still streaming.
                    await store.upsert(Flow(
                        id: flowID, request: request,
                        response: CapturedResponse(statusCode: code, headers: headers, body: nil),
                        startedAt: startedAt, sourceApp: sourceApp,
                        appliedRules: rules.isEmpty ? nil : rules
                    ))
                case let .body(chunk):
                    HTTPUtil.writeResponseChunk(channel: channel, data: chunk)
                    if capturedBody.count < captureCap {
                        let remaining = captureCap - capturedBody.count
                        capturedBody.append(chunk.count <= remaining ? chunk : chunk.prefix(remaining))
                    }
                case .end:
                    HTTPUtil.finishResponse(channel: channel, keepAlive: keepAlive)
                }
            }
            await store.upsert(Flow(
                id: flowID, request: request,
                response: CapturedResponse(statusCode: statusCode, headers: responseHeaders, body: capturedBody),
                startedAt: startedAt, completedAt: Date(), sourceApp: sourceApp,
                appliedRules: appliedRules.isEmpty ? nil : appliedRules
            ))
        } catch {
            if headWritten {
                // Response already started; end it and record what we relayed + the error.
                HTTPUtil.finishResponse(channel: channel, keepAlive: false)
                await store.upsert(Flow(
                    id: flowID, request: request,
                    response: CapturedResponse(statusCode: statusCode, headers: responseHeaders, body: capturedBody),
                    startedAt: startedAt, completedAt: Date(), error: error.localizedDescription,
                    sourceApp: sourceApp, appliedRules: appliedRules.isEmpty ? nil : appliedRules
                ))
            } else {
                await store.upsert(Flow(
                    id: flowID, request: request, startedAt: startedAt, completedAt: Date(),
                    error: error.localizedDescription, sourceApp: sourceApp
                ))
                HTTPUtil.writeResponse(
                    channel: channel, status: 502, headers: [],
                    body: Data("Loom upstream error: \(error.localizedDescription)\n".utf8), keepAlive: false
                )
            }
        }
    }
}
