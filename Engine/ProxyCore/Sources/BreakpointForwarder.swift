import Foundation
import SharedModels

/// Decorates the upstream forwarder so an armed breakpoint can hold an exchange
/// mid-flight for inspection/editing. Placed as the *outermost* decorator (outside
/// `RuleApplyingForwarder`), so a request-phase pause sees the request as the
/// client sent it — traffic rules then apply to whatever edit the operator makes —
/// and a response-phase pause sees the final response the client will receive.
///
/// Matching is decided once, up front, off the original request; if nothing
/// matches, forwarding is delegated untouched so streaming responses (SSE /
/// long-poll) keep streaming. Only a matched exchange takes the buffered path.
final class BreakpointForwarder: UpstreamForwarding {
    private let base: UpstreamForwarding
    private let store: BreakpointStore

    init(base: UpstreamForwarding, store: BreakpointStore) {
        self.base = base
        self.store = store
    }

    func forward(method: String, url: URL, headers: [HeaderPair], body: Data?) async throws -> ForwardResult {
        let originalMethod = method
        let originalURL = url.absoluteString

        var method = method
        var url = url
        var headers = headers
        var body = body

        // Request phase: hold the request as the client sent it, apply any edit.
        if let bp = store.firstMatch(method: originalMethod, url: originalURL, phase: .request) {
            let info = PendingBreakpoint(
                breakpointID: bp.id, phase: .request,
                method: method, url: url.absoluteString, requestHeaders: headers, requestBody: body
            )
            switch await store.hold(info) {
            case .abort:
                return Self.aborted()
            case let .proceed(edit):
                (method, url, headers, body) = Self.applyRequestEdit(edit, method: method, url: url, headers: headers, body: body)
            }
        }

        var result = try await base.forward(method: method, url: url, headers: headers, body: body)

        // Response phase: hold the final response before it reaches the client.
        // Matched off the *original* request so a request-phase URL edit can't
        // change whether the response pauses.
        if let bp = store.firstMatch(method: originalMethod, url: originalURL, phase: .response) {
            let info = PendingBreakpoint(
                breakpointID: bp.id, phase: .response,
                method: method, url: url.absoluteString, requestHeaders: headers, requestBody: body,
                statusCode: result.statusCode, responseHeaders: result.headers, responseBody: result.body
            )
            switch await store.hold(info) {
            case .abort:
                return Self.aborted()
            case let .proceed(edit):
                result = Self.applyResponseEdit(edit, to: result)
            }
        }

        return result
    }

    func forwardStream(method: String, url: URL, headers: [HeaderPair], body: RequestBody) -> AsyncThrowingStream<UpstreamResponseEvent, Error> {
        let urlString = url.absoluteString
        let matchesRequest = store.firstMatch(method: method, url: urlString, phase: .request) != nil
        let matchesResponse = store.firstMatch(method: method, url: urlString, phase: .response) != nil

        // Fast path: no breakpoint touches this exchange — delegate untouched so the
        // request body (and streaming responses) keep streaming chunk-by-chunk.
        guard matchesRequest || matchesResponse else {
            return base.forwardStream(method: method, url: url, headers: headers, body: body)
        }

        // A held exchange must be buffered (we may edit the request or the whole
        // response), so materialize the body first, then run the buffered path.
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let collected = try await body.collect()
                    let result = try await self.forward(method: method, url: url, headers: headers, body: collected)
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

    // MARK: - Edit application

    private static func applyRequestEdit(
        _ edit: BreakpointEdit, method: String, url: URL, headers: [HeaderPair], body: Data?
    ) -> (String, URL, [HeaderPair], Data?) {
        let newMethod = edit.method ?? method
        // Keep the original URL if the edit's replacement doesn't parse, rather than
        // silently dropping the request.
        let newURL = edit.url.flatMap { URL(string: $0) } ?? url
        let newHeaders = applyHeaderEdits(headers, set: edit.setHeaders, remove: edit.removeHeaders)
        let newBody = applyBody(edit.body, to: body)
        return (newMethod, newURL, newHeaders, newBody)
    }

    private static func applyResponseEdit(_ edit: BreakpointEdit, to result: ForwardResult) -> ForwardResult {
        var result = result
        if let statusCode = edit.statusCode { result.statusCode = statusCode }
        result.headers = applyHeaderEdits(result.headers, set: edit.setHeaders, remove: edit.removeHeaders)
        result.body = applyBody(edit.body, to: result.body) ?? Data()
        return result
    }

    /// Remove-by-name (case-insensitive) then set/overwrite, matching how replay
    /// and rule rewrites treat header edits.
    private static func applyHeaderEdits(_ headers: [HeaderPair], set: [HeaderPair]?, remove: [String]?) -> [HeaderPair] {
        var result = headers
        if let remove, !remove.isEmpty {
            let drop = Set(remove.map { $0.lowercased() })
            result.removeAll { drop.contains($0.name.lowercased()) }
        }
        for header in set ?? [] {
            if let index = result.firstIndex(where: { $0.name.caseInsensitiveCompare(header.name) == .orderedSame }) {
                result[index] = header
            } else {
                result.append(header)
            }
        }
        return result
    }

    private static func applyBody(_ override: BodyOverride, to body: Data?) -> Data? {
        switch override {
        case .keep: return body
        case .clear: return nil
        case let .replace(data): return data
        }
    }

    private static func aborted() -> ForwardResult {
        ForwardResult(
            statusCode: 502,
            headers: [HeaderPair(name: "Content-Type", value: "text/plain; charset=utf-8")],
            body: Data("Aborted by Loom breakpoint\n".utf8)
        )
    }
}
