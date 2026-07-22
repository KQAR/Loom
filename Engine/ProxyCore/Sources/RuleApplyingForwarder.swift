import Foundation
import SharedModels
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
        let plan = RuleEngine.planRequest(
            state: rules.snapshot(), method: method, url: url, headers: headers, body: body
        )
        if plan.delayMilliseconds > 0 {
            try? await Task.sleep(nanoseconds: UInt64(plan.delayMilliseconds) * 1_000_000)
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

        result = RuleEngine.applyResponseRewrites(plan.matched, to: result)
        result.appliedRules = plan.appliedRuleNames
        return result
    }

    private static func synthesize(_ mock: MockResponseAction) -> ForwardResult {
        var headers = mock.headers
        if let contentType = mock.contentType,
           !headers.contains(where: { $0.name.lowercased() == "content-type" }) {
            headers.append(HeaderPair(name: "Content-Type", value: contentType))
        }
        return ForwardResult(
            statusCode: mock.statusCode,
            headers: headers,
            body: mock.bodyText.map { Data($0.utf8) } ?? Data()
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
