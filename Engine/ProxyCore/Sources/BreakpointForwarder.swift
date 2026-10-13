import Foundation
import LoomSharedModels

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

    /// True while any armed breakpoint is scoped to a source app — see
    /// `RuleApplyingForwarder`: an app-scoped hold evaluated against a nil app
    /// fails closed, silently not holding the exchange the operator armed for.
    var requiresSourceAppResolution: Bool {
        store.armed().contains { !($0.match.sourceApp ?? "").isEmpty }
            || base.requiresSourceAppResolution
    }

    func forward(method: String, url: URL, headers: [HeaderPair], body: Data?) async throws -> ForwardResult {
        // Fold our own event stream (which owns the hold logic) into a buffered
        // result — one production path shared with `forwardStream`.
        try await forwardStream(method: method, url: url, headers: headers, body: .bytes(body)).collect()
    }

    /// The origin-less entry point (a client Loom couldn't identify); the real
    /// implementation is below, so a breakpoint can't hold on one path and not the other.
    func forwardStream(method: String, url: URL, headers: [HeaderPair], body: RequestBody) -> AsyncThrowingStream<UpstreamResponseEvent, Error> {
        forwardStream(method: method, url: url, headers: headers, body: body, origin: nil)
    }

    func forwardStream(
        method: String, url: URL, headers: [HeaderPair], body: RequestBody, origin: RequestOrigin?
    ) -> AsyncThrowingStream<UpstreamResponseEvent, Error> {
        forwardStream(
            method: method, url: url, headers: headers, body: body,
            origin: origin, clientProtocol: .http1, clientURLString: nil
        )
    }

    /// Passes the client's protocol through to the base forwarder. A hold changes
    /// *when* the request goes out and possibly what it says — never which protocol
    /// it travels on.
    func forwardStream(
        method: String, url: URL, headers: [HeaderPair], body: RequestBody,
        origin: RequestOrigin?, clientProtocol: ClientWireProtocol, clientURLString: String? = nil
    ) -> AsyncThrowingStream<UpstreamResponseEvent, Error> {
        let originalMethod = method
        let originalURL = url.absoluteString
        let requestBP = store.firstMatch(method: originalMethod, url: originalURL, phase: .request, origin: origin)
        let responseBP = store.firstMatch(method: originalMethod, url: originalURL, phase: .response, origin: origin)

        // Fast path: no breakpoint touches this exchange — delegate untouched so the
        // request body (and streaming responses) keep streaming chunk-by-chunk.
        guard requestBP != nil || responseBP != nil else {
            return base.forwardStream(
                method: method, url: url, headers: headers, body: body,
                origin: origin, clientProtocol: clientProtocol, clientURLString: clientURLString
            )
        }

        // A request-phase hold alone needs the request and nothing after it: once
        // released, the response streams. Buffering it anyway made every large
        // download through a request breakpoint fail at `BufferCap` for a response no
        // one was going to look at.
        guard let responseBP else {
            let base = self.base
            let store = self.store
            return DeferredResponseStream.events {
                let collected = try await body.collect(cap: .breakpoint)
                let info = PendingBreakpoint(
                    breakpointID: requestBP!.id, phase: .request,
                    method: method, url: url.absoluteString, requestHeaders: headers, requestBody: collected.body
                )
                switch await store.hold(info) {
                case .abort:
                    return (Self.events(of: Self.aborted()), nil)
                case let .proceed(edit):
                    let (method, url, headers, requestBody) = Self.applyRequestEdit(
                        edit, method: method, url: url, headers: headers, body: collected.body
                    )
                    // Base events — rule `.metadata` included — pass straight through.
                    return ([], base.forwardStream(
                        method: method, url: url, headers: headers,
                        body: .bytes(requestBody, trailers: collected.trailers),
                        origin: origin, clientProtocol: clientProtocol,
                        clientURLString: clientURLString
                    ))
                }
            }
        }

        // A response hold buffers the response (the operator may replace all of it),
        // but the base stream's rule `.metadata` is surfaced *immediately* — so a held
        // exchange that then fails upstream still records the rules that acted on it.
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var method = method
                    var url = url
                    var headers = headers
                    let collected = try await body.collect(cap: .breakpoint)
                    var body = collected.body
                    // Not editable at a breakpoint (the edit surface is method / URL /
                    // headers / body), but carried through it: a hold that silently
                    // dropped the client's trailer section would change the request in
                    // a way the operator never asked for and cannot see.
                    let requestTrailers = collected.trailers

                    // Request phase: hold the request as the client sent it, apply any edit.
                    if let bp = requestBP {
                        let info = PendingBreakpoint(
                            breakpointID: bp.id, phase: .request,
                            method: method, url: url.absoluteString, requestHeaders: headers, requestBody: body
                        )
                        switch await store.hold(info) {
                        case .abort:
                            Self.emit(Self.aborted(), into: continuation); return
                        case let .proceed(edit):
                            (method, url, headers, body) = Self.applyRequestEdit(edit, method: method, url: url, headers: headers, body: body)
                        }
                    }

                    // Forward through the base stream: pass rule `.metadata` straight
                    // out as it arrives, buffer the response for a possible response hold.
                    var statusCode = 200
                    var httpVersion: String?
                    var responseHeaders: [HeaderPair] = []
                    var responseBody = Data()
                    var responseTrailers: [HeaderPair]?
                    var transport: FlowTransport?
                    for try await event in base.forwardStream(
                        method: method, url: url, headers: headers,
                        body: .bytes(body, trailers: requestTrailers),
                        // Passed through even though a hold may have *edited* the URL:
                        // `NIOStreamingForwarder.requestTarget` honours the raw form
                        // only while the URL still agrees with it, so an edit wins
                        // here without this decorator having to detect one.
                        origin: origin, clientProtocol: clientProtocol,
                        clientURLString: clientURLString
                    ) {
                        switch event {
                        case let .metadata(rules): continuation.yield(.metadata(appliedRules: rules))
                        // Buffered like the rest of the response, not passed straight
                        // through: a held exchange emits nothing until the human
                        // releases it, and a transport arriving ahead of its own head
                        // would describe a response the consumer has not been given.
                        case let .transport(info): transport = (transport ?? FlowTransport()).merging(info)
                        case let .head(code, version, hdrs): statusCode = code; httpVersion = version; responseHeaders = hdrs
                        case let .body(chunk):
                            try BufferCap.breakpoint.check(holding: responseBody.count, adding: chunk.count, side: .response)
                            responseBody.append(chunk)
                        case let .end(trailers): responseTrailers = trailers
                        }
                    }
                    var result = ForwardResult(
                        statusCode: statusCode, httpVersion: httpVersion,
                        headers: responseHeaders, body: responseBody, trailers: responseTrailers,
                        transport: transport
                    )

                    // Response phase: hold the final response before it reaches the client.
                    // Matched off the *original* request so a request-phase URL edit can't
                    // change whether the response pauses.
                    do {
                        let bp = responseBP
                        let info = PendingBreakpoint(
                            breakpointID: bp.id, phase: .response,
                            method: method, url: url.absoluteString, requestHeaders: headers, requestBody: body,
                            statusCode: result.statusCode, responseHeaders: result.headers, responseBody: result.body
                        )
                        switch await store.hold(info) {
                        case .abort:
                            Self.emit(Self.aborted(), into: continuation); return
                        case let .proceed(edit):
                            result = Self.applyResponseEdit(edit, to: result)
                        }
                    }
                    Self.emit(result, into: continuation)
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Yield a buffered result to the client stream as head/body/end, then finish.
    private static func emit(_ result: ForwardResult, into continuation: AsyncThrowingStream<UpstreamResponseEvent, Error>.Continuation) {
        for event in events(of: result) { continuation.yield(event) }
        continuation.finish()
    }

    /// A buffered result as the events a stream carries it in.
    private static func events(of result: ForwardResult) -> [UpstreamResponseEvent] {
        var events: [UpstreamResponseEvent] = []
        if let transport = result.transport { events.append(.transport(transport)) }
        events.append(.head(statusCode: result.statusCode, httpVersion: result.httpVersion, headers: result.headers))
        if !result.body.isEmpty { events.append(.body(result.body)) }
        events.append(.end(trailers: result.trailers))
        return events
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
    /// and rule rewrites treat header edits — except that a set header keeps the
    /// position of the one it replaces here, rather than moving to the end. Kept
    /// separate from `RuleEngine.applyHeaderEdits` for that reason; the shared part
    /// is `[HeaderPair]`'s header-name equality.
    private static func applyHeaderEdits(_ headers: [HeaderPair], set: [HeaderPair]?, remove: [String]?) -> [HeaderPair] {
        var result = headers
        result.removeAll(namedAnyOf: remove ?? [])
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
