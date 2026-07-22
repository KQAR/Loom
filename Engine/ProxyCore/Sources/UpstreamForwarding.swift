import Foundation
import SharedModels

/// The upstream leg of a proxied exchange, factored out so the plain-HTTP path,
/// the TLS-interception path, and replay all re-send through one place — and so
/// tests can inject a deterministic stub instead of hitting the network.
struct ForwardResult: Sendable {
    var statusCode: Int
    var headers: [HeaderPair]
    var body: Data
    /// Names of traffic rules that acted on this exchange (set by
    /// `RuleApplyingForwarder`); copied onto the captured flow for audit.
    var appliedRules: [String] = []
}

/// A response as it arrives from upstream, so the proxy can relay it to the client
/// chunk-by-chunk (SSE / long-poll / large downloads) instead of buffering the
/// whole body first. `appliedRules` rides on `.head` since rules are known before
/// the response.
enum UpstreamResponseEvent: Sendable {
    case head(statusCode: Int, headers: [HeaderPair], appliedRules: [String])
    case body(Data)
    case end
}

protocol UpstreamForwarding: Sendable {
    func forward(method: String, url: URL, headers: [HeaderPair], body: Data?) async throws -> ForwardResult
    /// Streaming variant. The default adapter below turns any buffered `forward`
    /// into a single-shot stream, so only the NIO client and the rule decorator
    /// need to override it with real streaming.
    func forwardStream(method: String, url: URL, headers: [HeaderPair], body: Data?) -> AsyncThrowingStream<UpstreamResponseEvent, Error>
}

extension UpstreamForwarding {
    func forwardStream(method: String, url: URL, headers: [HeaderPair], body: Data?) -> AsyncThrowingStream<UpstreamResponseEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let result = try await forward(method: method, url: url, headers: headers, body: body)
                    continuation.yield(.head(statusCode: result.statusCode, headers: result.headers, appliedRules: result.appliedRules))
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
