import Foundation
import LoomSharedModels

/// The upstream leg of a proxied exchange, factored out so the plain-HTTP path,
/// the TLS-interception path, and replay all re-send through one place — and so
/// tests can inject a deterministic stub instead of hitting the network.
struct ForwardResult: Sendable {
    var statusCode: Int
    /// Upstream's HTTP version (nil for a synthesized mock/block/local response).
    var httpVersion: String?
    var headers: [HeaderPair]
    var body: Data
    /// Traffic rules that acted on this exchange (set by `RuleApplyingForwarder`);
    /// copied onto the captured flow for audit.
    var appliedRules: [AppliedRule] = []
}

/// A response as it arrives from upstream, so the proxy can relay it to the client
/// chunk-by-chunk (SSE / long-poll / large downloads) instead of buffering the
/// whole body first. `httpVersion` + `appliedRules` ride on `.head` since both are
/// known before the response body.
enum UpstreamResponseEvent: Sendable {
    case head(statusCode: Int, httpVersion: String?, headers: [HeaderPair], appliedRules: [AppliedRule])
    case body(Data)
    case end
}

protocol UpstreamForwarding: Sendable {
    /// Buffered send — the whole request body is already in hand (replay, or a body
    /// a rule/breakpoint had to materialize). Also the buffered fallback the
    /// decorators use when they must see the full body.
    func forward(method: String, url: URL, headers: [HeaderPair], body: Data?) async throws -> ForwardResult
    /// Streaming send: the request body is a back-pressured `RequestBody` and the
    /// response is relayed chunk-by-chunk. The default adapter below drains the body
    /// and calls buffered `forward`, so test stubs only need `forward`; the NIO
    /// client and the decorators override this with real streaming.
    func forwardStream(method: String, url: URL, headers: [HeaderPair], body: RequestBody) -> AsyncThrowingStream<UpstreamResponseEvent, Error>
}

extension UpstreamForwarding {
    func forwardStream(method: String, url: URL, headers: [HeaderPair], body: RequestBody) -> AsyncThrowingStream<UpstreamResponseEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let collected = try await body.collect()
                    let result = try await forward(method: method, url: url, headers: headers, body: collected)
                    continuation.yield(.head(statusCode: result.statusCode, httpVersion: result.httpVersion, headers: result.headers, appliedRules: result.appliedRules))
                    if !result.body.isEmpty { continuation.yield(.body(result.body)) }
                    continuation.yield(.end)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
