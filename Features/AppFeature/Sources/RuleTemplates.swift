import Foundation
import LoomSharedModels

/// One-click rule shapes offered in the request row's context menu. The human
/// picks a captured flow and stamps a rule out of it; fine-tuning (pattern,
/// body, group) happens afterwards via MCP or the rules panel.
public enum RuleTemplate: Equatable, Sendable {
    /// Pin the captured response as a mock for this URL + method.
    case mockResponse
    /// Block exactly this URL (prefix, query-insensitive).
    case blockURL
    /// Block every request to this host.
    case blockHost
}

enum RuleFactory {
    static func rule(from flow: Flow, template: RuleTemplate) -> TrafficRule? {
        let base = urlWithoutQuery(flow.request.url)
        switch template {
        case .mockResponse:
            let response = flow.response
            let contentType = response?.headers.value(named: "content-type")
            return TrafficRule(
                name: "Mock \(shortPath(flow.request.url))",
                comment: "Pinned from a captured \(flow.request.method) exchange",
                match: RuleMatch(urlPattern: base, methods: [flow.request.method]),
                actions: RuleActions(route: .mock(MockResponseAction(
                    statusCode: response?.statusCode ?? 200,
                    bodyText: response?.body.flatMap { String(data: $0, encoding: .utf8) },
                    contentType: contentType ?? "application/json"
                )))
            )

        case .blockURL:
            return TrafficRule(
                name: "Block \(shortPath(flow.request.url))",
                match: RuleMatch(urlPattern: base, methods: []),
                actions: RuleActions(route: .block)
            )

        case .blockHost:
            guard let host = flow.host else { return nil }
            // Regex instead of a `*host*` glob so `api.example.com` can't also
            // match `api.example.com.evil.io`.
            let pattern = "://" + NSRegularExpression.escapedPattern(for: host) + #"(:\d+)?(/|$)"#
            return TrafficRule(
                name: "Block \(host)",
                match: RuleMatch(urlPattern: pattern, isRegex: true),
                actions: RuleActions(route: .block)
            )
        }
    }

    /// The URL with query + fragment stripped — as a prefix pattern it matches
    /// the endpoint regardless of query parameters (the common mock intent).
    private static func urlWithoutQuery(_ raw: String) -> String {
        guard var components = URLComponents(string: raw) else { return raw }
        components.query = nil
        components.fragment = nil
        return components.string ?? raw
    }

    /// Last path segments for a compact rule name, e.g. `phi/home`.
    private static func shortPath(_ raw: String) -> String {
        let path = URLComponents(string: raw)?.path ?? raw
        let segments = path.split(separator: "/").suffix(2)
        return segments.isEmpty ? "/" : segments.joined(separator: "/")
    }
}
