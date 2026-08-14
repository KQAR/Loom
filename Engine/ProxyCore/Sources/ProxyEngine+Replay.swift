import Foundation
import LoomSharedModels

/// `FlowReplaying`. Both forms fold the same `forwardStream` the live proxy
/// path uses, so a replay goes through the identical rule and breakpoint
/// decorators — never a second write path.
extension ProxyEngine {
    public func replay(id: UUID, overrides: ReplayOverrides) async throws -> Flow {
        guard let source = await store.flow(id: id) else {
            throw ProxyControlError.flowNotFound(id)
        }
        return try await replay(flow: source, overrides: overrides)
    }

    /// Replay a caller-supplied flow directly — no store lookup, so it works for
    /// an embedder that owns its own retention (see the protocol doc). Shares the
    /// override-application + forward + capture path with `replay(id:)`.
    public func replay(flow source: Flow, overrides: ReplayOverrides) async throws -> Flow {
        let id = source.id
        let method = overrides.method ?? source.request.method
        let urlString = overrides.url ?? source.request.url
        guard let url = URL(string: urlString) else {
            throw ProxyControlError.invalidURL(urlString)
        }

        var headers = source.request.headers
        if let removals = overrides.removeHeaders {
            let lowered = Set(removals.map { $0.lowercased() })
            headers.removeAll { lowered.contains($0.name.lowercased()) }
        }
        if let sets = overrides.setHeaders {
            for header in sets {
                headers.removeAll { $0.name.lowercased() == header.name.lowercased() }
                headers.append(header)
            }
        }

        let body: Data?
        switch overrides.body {
        case .keep: body = source.request.body
        case .clear: body = nil
        case let .replace(data): body = data
        }
        // Stated, not inherited: a replay is issued by Loom's own NIO client, which
        // speaks HTTP/1.1 whatever the original client negotiated. Copying the
        // source flow's version across would make a replayed h2 request claim an h2
        // hop that never happened.
        let capturedRequest = CapturedRequest(
            method: method, url: urlString, httpVersion: "HTTP/1.1", headers: headers, body: body
        )

        let newID = UUID()
        let startedAt = Date()
        // Replay consumes the same event stream as live traffic (not the buffered
        // `forward`), so rule hits arrive via `.metadata` before any response or
        // error — a replay that fails to connect still records its applied rules.
        var appliedRules: [AppliedRule] = []
        var statusCode = 0
        var firstByteAt: Date?
        var httpVersion: String?
        var responseHeaders: [HeaderPair] = []
        var responseBody = Data()
        var responseTrailers: [HeaderPair]?
        var transport: FlowTransport?
        do {
            // A replay inherits the origin of the flow it re-sends: replaying an app's
            // request should behave like that app's request, including for rules and
            // breakpoints scoped to it.
            for try await event in forwarder.forwardStream(
                method: method, url: url, headers: headers, body: .bytes(body),
                origin: RequestOrigin(flow: source),
                // A replay re-sends over the protocol the original used, for the same
                // reason it inherits the origin: a diff between an h2 capture and an
                // h1 replay would report differences that are Loom's, not the change
                // under test.
                clientProtocol: ClientWireProtocol(
                    httpVersion: source.request.httpVersion,
                    clientTLSVersion: source.transport?.clientTLSVersion
                )
            ) {
                switch event {
                case let .metadata(rules): appliedRules = rules
                case let .transport(info): transport = (transport ?? FlowTransport()).merging(info)
                case let .head(code, version, headers):
                    firstByteAt = Date()
                    statusCode = code; httpVersion = version; responseHeaders = headers
                case let .body(chunk): responseBody.append(chunk)
                case let .end(trailers): responseTrailers = trailers
                }
            }
            let flow = Flow(
                id: newID,
                request: capturedRequest,
                startedAt: startedAt,
                outcome: .completed(
                    CapturedResponse(
                        statusCode: statusCode, httpVersion: httpVersion, headers: responseHeaders,
                        body: responseBody, trailers: responseTrailers
                    ),
                    at: Date()
                ),
                firstByteAt: firstByteAt,
                replayedFrom: id,
                appliedRules: appliedRules.isEmpty ? nil : appliedRules,
                transport: transport
            )
            await store.upsert(flow, force: true) // explicit action: record even when capture is paused
            return flow
        } catch {
            let flow = Flow(
                id: newID,
                request: capturedRequest,
                startedAt: startedAt,
                outcome: .failed(FlowError(error.localizedDescription), at: Date(), partialResponse: nil),
                replayedFrom: id,
                appliedRules: appliedRules.isEmpty ? nil : appliedRules,
                transport: transport
            )
            await store.upsert(flow, force: true)
            throw ProxyControlError.replayFailed(error.localizedDescription)
        }
    }
}
