import Foundation
import SharedModels

/// Pure rule evaluation — no I/O, no locks — so the semantics are unit-testable
/// in isolation. `RuleApplyingForwarder` executes the plans this produces.
///
/// Semantics: every active rule is matched against the *original* request, so
/// rule order never changes which rules match. Matching rules then apply in
/// list order — request rewrites and re-mapping compose (later rules override
/// earlier ones on the same field); `block` beats `mockResponse` beats
/// `mapLocal` when several short-circuits match; the largest delay wins.
enum RuleEngine {
    /// The response is synthesized instead of fetched upstream.
    enum ShortCircuit: Equatable {
        case block(ruleName: String)
        case mock(MockResponseAction)
        case localFile(MapLocalAction)
    }

    /// Everything the forwarding path needs to execute one matched exchange.
    struct RequestPlan {
        var method: String
        var url: URL
        var headers: [HeaderPair]
        var body: Data?
        var shortCircuit: ShortCircuit?
        var delayMilliseconds: Int
        /// Matching active rules in evaluation order (drives response rewrites
        /// and the flow's `appliedRules` audit trail).
        var matched: [TrafficRule]

        var appliedRuleNames: [String] { matched.map(\.name) }
    }

    static func planRequest(
        state: RulesState,
        method: String,
        url: URL,
        headers: [HeaderPair],
        body: Data?
    ) -> RequestPlan {
        var plan = RequestPlan(
            method: method, url: url, headers: headers, body: body,
            shortCircuit: nil, delayMilliseconds: 0, matched: []
        )
        let urlString = url.absoluteString
        let matched = state.activeRules.filter { $0.match.matches(method: method, url: urlString) }
        guard !matched.isEmpty else { return plan }
        plan.matched = matched

        for rule in matched {
            let actions = rule.actions
            if let rewrite = actions.rewriteRequest, !rewrite.isEmpty {
                if let newMethod = rewrite.method { plan.method = newMethod.uppercased() }
                plan.headers = applyHeaderEdits(plan.headers, set: rewrite.setHeaders, remove: rewrite.removeHeaders)
                if let bodyText = rewrite.bodyText { plan.body = Data(bodyText.utf8) }
            }
            applyRequestSubstitutions(actions.activeRequestSubstitutions, to: &plan)
            if let map = actions.mapRemote, !isExcluded(plan.url, by: map.excludePattern),
               let mapped = retarget(plan.url, at: map.destination) {
                plan.url = mapped
                // By default the Host header should follow the new origin; drop it so
                // the forwarder derives it from the mapped URL. keepHostHeader leaves
                // the original Host in place.
                if !map.keepHostHeader {
                    plan.headers.removeAll { $0.name.lowercased() == "host" }
                }
            }
            if let delay = actions.delayMilliseconds {
                plan.delayMilliseconds = max(plan.delayMilliseconds, delay)
            }
            if actions.block {
                plan.shortCircuit = .block(ruleName: rule.name) // block always wins
            } else if plan.shortCircuit == nil, let mock = actions.mockResponse {
                plan.shortCircuit = .mock(mock)
            } else if plan.shortCircuit == nil, let local = actions.mapLocal {
                plan.shortCircuit = .localFile(local)
            } else if case .localFile = plan.shortCircuit, let mock = actions.mockResponse {
                plan.shortCircuit = .mock(mock) // mock outranks a local file
            }
        }
        return plan
    }

    static func applyResponseRewrites(_ matched: [TrafficRule], to result: ForwardResult) -> ForwardResult {
        var result = result
        for rule in matched {
            if let rewrite = rule.actions.rewriteResponse, !rewrite.isEmpty {
                if let status = rewrite.statusCode { result.statusCode = status }
                result.headers = applyHeaderEdits(result.headers, set: rewrite.setHeaders, remove: rewrite.removeHeaders)
                if let bodyText = rewrite.bodyText { result.body = Data(bodyText.utf8) }
            }
            applyResponseSubstitutions(rule.actions.activeResponseSubstitutions, to: &result)
        }
        return result
    }

    /// Apply "modify request" substitutions in place over the plan's url / header
    /// values / body text.
    private static func applyRequestSubstitutions(_ subs: [SubstitutionRule], to plan: inout RequestPlan) {
        for sub in subs {
            switch sub.field {
            case .url:
                if let newURL = URL(string: sub.apply(to: plan.url.absoluteString)) { plan.url = newURL }
            case .header:
                plan.headers = plan.headers.map { HeaderPair(name: $0.name, value: sub.apply(to: $0.value)) }
            case .body:
                if let body = plan.body, let text = String(data: body, encoding: .utf8) {
                    plan.body = Data(sub.apply(to: text).utf8)
                }
            }
        }
    }

    /// Apply "modify response" substitutions in place over header values / body text.
    private static func applyResponseSubstitutions(_ subs: [SubstitutionRule], to result: inout ForwardResult) {
        for sub in subs {
            switch sub.field {
            case .url:
                continue // no URL on a response
            case .header:
                result.headers = result.headers.map { HeaderPair(name: $0.name, value: sub.apply(to: $0.value)) }
            case .body:
                if let text = String(data: result.body, encoding: .utf8) {
                    result.body = Data(sub.apply(to: text).utf8)
                }
            }
        }
    }

    /// True when the URL matches the mapRemote exclude pattern (regex if it parses
    /// as one, else the same whole-string glob the matcher uses).
    private static func isExcluded(_ url: URL, by pattern: String?) -> Bool {
        guard let pattern, !pattern.isEmpty else { return false }
        let s = url.absoluteString
        if let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
           regex.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil {
            return true
        }
        return SSLScope.matches(pattern: pattern, host: s)
    }

    /// Removals first, then sets (a set of the same name replaces, not duplicates) —
    /// the same composition `ReplayOverrides` uses.
    static func applyHeaderEdits(_ headers: [HeaderPair], set: [HeaderPair], remove: [String]) -> [HeaderPair] {
        var headers = headers
        if !remove.isEmpty {
            let lowered = Set(remove.map { $0.lowercased() })
            headers.removeAll { lowered.contains($0.name.lowercased()) }
        }
        for header in set {
            headers.removeAll { $0.name.lowercased() == header.name.lowercased() }
            headers.append(header)
        }
        return headers
    }

    /// Swap the URL's origin (scheme/host/port) for the destination's, keeping
    /// path + query. Returns nil when either side fails to parse.
    static func retarget(_ url: URL, at destination: String) -> URL? {
        guard let target = URLComponents(string: destination), let host = target.host,
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return nil }
        components.scheme = target.scheme ?? components.scheme
        components.host = host
        components.port = target.port
        return components.url
    }
}
