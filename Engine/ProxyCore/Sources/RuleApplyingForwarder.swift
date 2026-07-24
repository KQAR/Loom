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

    func forward(method: String, url: URL, headers: [HeaderPair], body: Data?) async throws -> ForwardResult {
        // Fold our own event stream into a buffered result, so `forward` and
        // `forwardStream` are one production path that can never disagree — applied
        // rules come from the same `.metadata` event either way.
        var statusCode = 200
        var httpVersion: String?
        var responseHeaders: [HeaderPair] = []
        var responseBody = Data()
        for try await event in forwardStream(method: method, url: url, headers: headers, body: .bytes(body)) {
            switch event {
            case .metadata: break // applied rules travel on the event stream, not the buffered result
            case let .head(code, version, headers): statusCode = code; httpVersion = version; responseHeaders = headers
            case let .body(chunk): responseBody.append(chunk)
            case .end: break
            }
        }
        return ForwardResult(
            statusCode: statusCode, httpVersion: httpVersion, headers: responseHeaders, body: responseBody
        )
    }

    /// Execute an already-computed plan. Taking the plan as a parameter (rather
    /// than re-planning) means the `touchesResponse` decision in `forwardStream`
    /// and the plan actually run can't disagree if rules mutate mid-request.
    private func execute(plan: RuleEngine.RequestPlan) async throws -> ForwardResult {
        if plan.delayMilliseconds > 0 {
            // `try await` (not `try?`) so a cancelled — client-gone — request
            // aborts here instead of sleeping then forwarding anyway.
            try await Task.sleep(nanoseconds: UInt64(plan.delayMilliseconds) * 1_000_000)
        }

        var result: ForwardResult
        switch plan.shortCircuit {
        case nil:
            result = try await base.forward(
                method: plan.method, url: plan.url, headers: plan.headers, body: plan.body
            )
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

    /// Stream the request body straight through when no matched rule needs the whole
    /// body (or the whole response); otherwise buffer it. Buffering is required for a
    /// short-circuit (block/mock/mapLocal — the body is discarded but still drained +
    /// captured), a request-body rewrite/substitution, or a response rewrite/
    /// substitution (needs the full response). Non-body request edits (method / URL /
    /// headers / mapRemote / URL substitutions) and delay apply on the streaming path
    /// too.
    func forwardStream(method: String, url: URL, headers: [HeaderPair], body: RequestBody) -> AsyncThrowingStream<UpstreamResponseEvent, Error> {
        let state = rules.snapshot()
        let matched = state.activeRules.filter { $0.match.matches(method: method, url: url.absoluteString) }
        let needsBuffering = matched.contains { rule in
            let a = rule.actions
            switch a.route {
            case .passthrough, .mapRemote: break // retarget is a non-body edit
            case .block, .mock, .mapLocal: return true // short-circuit: drain + capture the body
            }
            if a.rewriteRequest?.bodyText != nil { return true }
            if a.activeRequestSubstitutions.contains(where: { $0.field == .body }) { return true }
            if a.rewriteResponse?.isEmpty == false { return true }
            if !a.activeResponseSubstitutions.isEmpty { return true }
            return false
        }

        if needsBuffering {
            // Materialize the body, then run the SAME plan against it.
            return AsyncThrowingStream { continuation in
                let task = Task {
                    do {
                        let collected = try await body.collect()
                        let plan = RuleEngine.planRequest(state: state, method: method, url: url, headers: headers, body: collected)
                        // Emit rule hits before running the plan so they survive an
                        // upstream failure (the exchange records what matched even if
                        // the connection never completes).
                        if !plan.appliedRules.isEmpty { continuation.yield(.metadata(appliedRules: plan.appliedRules)) }
                        let result = try await self.execute(plan: plan)
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

        // Streaming: plan with no body so only the non-body request edits apply
        // (URL/host/headers/method); the real body streams through untouched.
        let plan = RuleEngine.planRequest(state: state, method: method, url: url, headers: headers, body: nil)
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
                    for try await event in base.forwardStream(method: planMethod, url: planURL, headers: planHeaders, body: body) {
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
    private static func serveLocalFile(_ local: MapLocalAction) -> ForwardResult {
        let url = URL(fileURLWithPath: local.path)
        guard let data = try? Data(contentsOf: url) else {
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
