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
}

/// The lifecycle of one proxied exchange, so the proxy can relay a response to the
/// client chunk-by-chunk (SSE / long-poll / large downloads) instead of buffering the
/// whole body first. Ordering: `metadata?` → `head` → `body`* → `end` (a terminal
/// `end`, or the stream finishes throwing on failure).
enum UpstreamResponseEvent: Sendable {
    /// Exchange-level metadata known *before* the response — currently the traffic
    /// rules that acted on the request. Emitted once, first, by `RuleApplyingForwarder`,
    /// and omitted entirely when no rule matched (so a no-rule passthrough yields no
    /// extra event). Because it precedes the network call, it is the reason a failed
    /// exchange can still record its rule hits: it arrives before any `head` or error.
    case metadata(appliedRules: [AppliedRule])
    case head(statusCode: Int, httpVersion: String?, headers: [HeaderPair])
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
                    continuation.yield(.head(statusCode: result.statusCode, httpVersion: result.httpVersion, headers: result.headers))
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

extension AsyncThrowingStream where Element == UpstreamResponseEvent, Failure == Error {
    /// Fold a response event stream into a buffered `ForwardResult` — the single place
    /// that reassembles `.head` / `.body` / `.end`. Applied rules ride the `.metadata`
    /// event and are consumed there (`StreamRelay` / replay), so they are not carried on
    /// the buffered result. Shared by every buffered `forward`; replay folds inline
    /// instead because it needs the rules even when the stream fails mid-flight.
    func collect() async throws -> ForwardResult {
        var statusCode = 200
        var httpVersion: String?
        var headers: [HeaderPair] = []
        var body = Data()
        for try await event in self {
            switch event {
            case .metadata: break
            case let .head(code, version, hdrs): statusCode = code; httpVersion = version; headers = hdrs
            case let .body(chunk): body.append(chunk)
            case .end: break
            }
        }
        return ForwardResult(statusCode: statusCode, httpVersion: httpVersion, headers: headers, body: body)
    }
}
