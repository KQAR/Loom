import Foundation
import LoomSharedModels
import UniformTypeIdentifiers

/// Decorates the real upstream forwarder with the traffic-rule engine. Because
/// the plain-HTTP path, the TLS-interception path and replay all re-send through
/// `UpstreamForwarding.forward`, wrapping it here applies rules to every
/// exchange with exactly one implementation — never fork a second write path.
final class RuleApplyingForwarder: UpstreamForwarding {
    private let base: UpstreamForwarding
    private let rules: RulesConfig

    init(base: UpstreamForwarding, rules: RulesConfig) {
        self.base = base
        self.rules = rules
    }

    /// True while any enabled rule is scoped to a source app — only then must
    /// forwarding wait for the resolver (an app-scoped rule evaluated against a
    /// nil app fails closed, which would silently skip the rule the user armed).
    var requiresSourceAppResolution: Bool {
        let state = rules.snapshot()
        // `applies`, not `isEnabled` — the same three switches the matcher reads, so
        // a rule in a switched-off group cannot make every exchange wait for a
        // resolution no rule will use.
        return (state.enabled && state.rules.contains { state.applies($0) && !($0.match.sourceApp ?? "").isEmpty })
            || base.requiresSourceAppResolution
    }

    func forward(method: String, url: URL, headers: [HeaderPair], body: Data?) async throws -> ForwardResult {
        // Fold our own event stream into a buffered result, so `forward` and
        // `forwardStream` are one production path that can never disagree.
        try await forwardStream(method: method, url: url, headers: headers, body: .bytes(body)).collect()
    }

    /// Execute an already-computed plan. Taking the plan as a parameter (rather
    /// than re-planning) means the `touchesResponse` decision in `forwardStream`
    /// and the plan actually run can't disagree if rules mutate mid-request.
    private func execute(
        plan: RuleEngine.RequestPlan,
        requestTrailers: [HeaderPair]? = nil,
        clientProtocol: ClientWireProtocol = .http1
    ) async throws -> ForwardResult {
        if plan.delayMilliseconds > 0 {
            // `try await` (not `try?`) so a cancelled — client-gone — request
            // aborts here instead of sleeping then forwarding anyway.
            try await Task.sleep(nanoseconds: UInt64(plan.delayMilliseconds) * 1_000_000)
        }

        var result: ForwardResult
        switch plan.shortCircuit {
        case nil:
            // Through `forwardStream` rather than the buffered `forward`, because
            // that is the only entry point a request trailer section can travel on:
            // `forward` takes bytes and nothing else, deliberately, since the bodies
            // it exists for (a mock, a replay) have no client behind them.
            result = try await base.forwardStream(
                method: plan.method, url: plan.url, headers: plan.headers,
                body: .bytes(plan.body, trailers: requestTrailers),
                origin: nil, clientProtocol: clientProtocol
            ).collect()
        case let .block(ruleName):
            result = ForwardResult(
                statusCode: 403,
                headers: [HeaderPair(name: "Content-Type", value: "text/plain; charset=utf-8")],
                body: Data("Blocked by Loom rule \"\(ruleName)\"\n".utf8)
            )
        case let .mock(mock):
            result = Self.synthesize(mock)
        case let .localFile(local):
            result = Self.serveLocalFile(local)
        }

        // Applied rules are not stamped on the result here: the caller emits them as a
        // leading `.metadata` event (from `plan.appliedRules`), which is the single
        // carrier that also survives a failure before any response.
        return RuleEngine.applyResponseRewrites(plan.matched, to: result)
    }

    /// The origin-less entry point: an exchange whose client Loom couldn't identify.
    /// Delegates to the one implementation below, so a rule can't apply on one path
    /// and not the other.
    func forwardStream(method: String, url: URL, headers: [HeaderPair], body: RequestBody) -> AsyncThrowingStream<UpstreamResponseEvent, Error> {
        forwardStream(method: method, url: url, headers: headers, body: body, origin: nil)
    }

    /// Carries the client's protocol down to the base forwarder, which is what
    /// decides the upstream leg. A decorator that dropped it would silently put every
    /// ruled exchange back on HTTP/1.1 — including the gRPC calls this exists for.
    func forwardStream(
        method: String, url: URL, headers: [HeaderPair], body: RequestBody,
        origin: RequestOrigin?, clientProtocol: ClientWireProtocol
    ) -> AsyncThrowingStream<UpstreamResponseEvent, Error> {
        plan(method: method, url: url, headers: headers, body: body,
             origin: origin, clientProtocol: clientProtocol)
    }

    /// Stream the request body straight through when no matched rule needs the whole
    /// body (or the whole response); otherwise buffer it. Buffering is required for a
    /// short-circuit (block/mock/mapLocal — the body is discarded but still drained +
    /// captured), a request-body rewrite/substitution, or a response rewrite/
    /// substitution (needs the full response). Non-body request edits (method / URL /
    /// headers / mapRemote / URL substitutions) and delay apply on the streaming path
    /// too.
    func forwardStream(
        method: String, url: URL, headers: [HeaderPair], body: RequestBody, origin: RequestOrigin?
    ) -> AsyncThrowingStream<UpstreamResponseEvent, Error> {
        plan(method: method, url: url, headers: headers, body: body, origin: origin, clientProtocol: .http1)
    }

    private func plan(
        method: String, url: URL, headers: [HeaderPair], body: RequestBody,
        origin: RequestOrigin?, clientProtocol: ClientWireProtocol
    ) -> AsyncThrowingStream<UpstreamResponseEvent, Error> {
        // Matched once and threaded into the plan below: this used to filter here to
        // decide `needsBuffering` and then let `planRequest` filter the same rules
        // against the same request all over again, so every active rule's predicate
        // ran twice per exchange.
        let matched = RuleEngine.matchingRules(state: rules.snapshot(), method: method, url: url, origin: origin)
        let needsBuffering = matched.contains { rule in
            let a = rule.actions
            switch a.route {
            case .passthrough, .mapRemote: break // retarget is a non-body edit
            case .block, .mock, .mapLocal: return true // short-circuit: drain + capture the body
            }
            if a.rewriteRequest?.bodyText != nil { return true }
            // `contains`, never `activeRequestSubstitutions.contains` — the latter
            // builds a filtered array per matched rule per exchange to ask a
            // yes/no question.
            if a.requestSubstitutions.contains(where: { !$0.isEmpty && $0.field == .body }) { return true }
            if a.rewriteResponse?.isEmpty == false { return true }
            if a.hasActiveResponseSubstitutions { return true }
            return false
        }

        if needsBuffering {
            // Materialize the body, then run the SAME plan against it.
            return AsyncThrowingStream { continuation in
                let task = Task {
                    do {
                        let collected = try await body.collect()
                        let plan = RuleEngine.planRequest(matched: matched, method: method, url: url, headers: headers, body: collected.body)
                        // Emit rule hits before running the plan so they survive an
                        // upstream failure (the exchange records what matched even if
                        // the connection never completes).
                        if !plan.appliedRules.isEmpty { continuation.yield(.metadata(appliedRules: plan.appliedRules)) }
                        // Draining the body is what made the client's trailer section
                        // knowable; carrying it forward is what stops a rule that
                        // merely rewrites a header from also eating it.
                        let result = try await self.execute(
                            plan: plan, requestTrailers: collected.trailers, clientProtocol: clientProtocol
                        )
                        continuation.yield(.head(statusCode: result.statusCode, httpVersion: result.httpVersion, headers: result.headers))
                        if !result.body.isEmpty { continuation.yield(.body(result.body)) }
                        continuation.yield(.end(trailers: result.trailers))
                        continuation.finish()
                    } catch {
                        continuation.finish(throwing: error)
                    }
                }
                continuation.onTermination = { _ in task.cancel() }
            }
        }

        // Streaming: plan with no body so only the non-body request edits apply
        // (URL/host/headers/method); the real body streams through untouched.
        let plan = RuleEngine.planRequest(matched: matched, method: method, url: url, headers: headers, body: nil)
        let base = self.base
        let appliedRules = plan.appliedRules
        let delayMs = plan.delayMilliseconds
        let planMethod = plan.method
        let planURL = plan.url
        let planHeaders = plan.headers
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    // Cancellation (client gone) aborts the delay instead of
                    // sleeping then forwarding anyway.
                    if delayMs > 0 { try await Task.sleep(nanoseconds: UInt64(delayMs) * 1_000_000) }
                    // Emit rule hits before touching the network so they survive an
                    // upstream failure that throws before any response head.
                    if !appliedRules.isEmpty { continuation.yield(.metadata(appliedRules: appliedRules)) }
                    for try await event in base.forwardStream(
                        method: planMethod, url: planURL, headers: planHeaders, body: body,
                        origin: origin, clientProtocol: clientProtocol
                    ) {
                        // The base (NIO) forwarder carries no rules; forward its events
                        // untouched — the leading `.metadata` above is the rule carrier.
                        continuation.yield(event)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func synthesize(_ mock: MockResponseAction) -> ForwardResult {
        var headers = mock.headers
        if let contentType = mock.contentType, !headers.contains(named: "content-type") {
            headers.append(HeaderPair(name: "Content-Type", value: contentType))
        }
        return ForwardResult(
            statusCode: mock.statusCode,
            headers: headers,
            body: mock.resolvedBody()
        )
    }

    /// Serve the mapped file, or an honest 404 naming the missing path — a mock
    /// that silently degrades to the real upstream would be far more confusing.
    static func serveLocalFile(_ local: MapLocalAction) -> ForwardResult {
        let url = URL(fileURLWithPath: local.path)
        guard let data = try? Data(contentsOf: url) else {
            Log.rules.error("mapLocal could not read \(local.path, privacy: .public); serving 404 instead of the mapped file.")
            return ForwardResult(
                statusCode: 404,
                headers: [HeaderPair(name: "Content-Type", value: "text/plain; charset=utf-8")],
                body: Data("Loom mapLocal: cannot read \(local.path)\n".utf8)
            )
        }
        let contentType = local.contentType
            ?? UTType(filenameExtension: url.pathExtension)?.preferredMIMEType
            ?? "application/octet-stream"
        return ForwardResult(
            statusCode: local.statusCode,
            headers: [HeaderPair(name: "Content-Type", value: contentType)],
            body: data
        )
    }
}
