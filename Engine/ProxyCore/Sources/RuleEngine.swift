import Foundation
import LoomSharedModels

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

        /// Structured audit trail (rule id + name) copied onto the captured flow.
        var appliedRules: [AppliedRule] { matched.map { AppliedRule(id: $0.id, name: $0.name) } }
    }

    /// `origin` (who sent the request) participates in matching, so a rule can be
    /// scoped to one app or device; nil means "unknown client", which an
    /// origin-scoped rule deliberately never matches.
    static func planRequest(
        state: RulesState,
        method: String,
        url: URL,
        headers: [HeaderPair],
        body: Data?,
        origin: RequestOrigin? = nil
    ) -> RequestPlan {
        var plan = RequestPlan(
            method: method, url: url, headers: headers, body: body,
            shortCircuit: nil, delayMilliseconds: 0, matched: []
        )
        let urlString = url.absoluteString
        let matched = state.activeRules.filter { $0.match.matches(method: method, url: urlString, origin: origin) }
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
            switch actions.route {
            case .passthrough:
                break
            case let .mapRemote(map):
                if !isExcluded(plan.url, by: map.excludePattern) {
                    if let mapped = retarget(plan.url, at: map.destination) {
                        plan.url = mapped
                        // By default the Host header should follow the new origin; drop it so
                        // the forwarder derives it from the mapped URL. keepHostHeader leaves
                        // the original Host in place.
                        if !map.keepHostHeader {
                            plan.headers.removeAll { $0.name.lowercased() == "host" }
                        }
                    } else {
                        // The rule matched and is reported in `appliedRules`, but the
                        // destination didn't parse, so the request went to the original
                        // origin after all. Silently that reads as "the map applied" —
                        // an agent would trust a redirect that never happened.
                        Log.rules.error("""
                        Rule \(rule.name, privacy: .public) could not map to \
                        \(map.destination, privacy: .public) (unparseable destination); \
                        the request went to its original origin.
                        """)
                    }
                }
            case .block:
                plan.shortCircuit = .block(ruleName: rule.name) // block always wins
            case let .mock(mock):
                // First mock wins; a mock also outranks an earlier localFile.
                if plan.shortCircuit == nil { plan.shortCircuit = .mock(mock) }
                else if case .localFile = plan.shortCircuit { plan.shortCircuit = .mock(mock) }
            case let .mapLocal(local):
                if plan.shortCircuit == nil { plan.shortCircuit = .localFile(local) }
            }
            if let delay = actions.delayMilliseconds {
                plan.delayMilliseconds = max(plan.delayMilliseconds, delay)
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
        guard let pattern else { return false }
        return Pattern.matchesLoosely(pattern, url.absoluteString)
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
