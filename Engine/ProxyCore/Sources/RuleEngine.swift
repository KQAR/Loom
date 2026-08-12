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

    /// Which active rules match this request, in list order. The one place matching
    /// happens, so a caller that needs the matches *before* planning (to decide
    /// whether the body must be buffered) doesn't have to re-derive them — running
    /// every rule's predicate twice per exchange is the whole reason this is
    /// separate from `planRequest`.
    ///
    /// `origin` (who sent the request) participates in matching, so a rule can be
    /// scoped to one app or device; nil means "unknown client", which an
    /// origin-scoped rule deliberately never matches.
    static func matchingRules(
        state: RulesState, method: String, url: URL, origin: RequestOrigin? = nil
    ) -> [TrafficRule] {
        guard state.enabled else { return [] }
        // Prepared once for the whole list: `RuleMatch.matches(method:url:)` builds a
        // context per call, so matching N rules used to parse the URL N times (any rule
        // with a host/query predicate) and re-encode it N times (any glob rule). Same
        // verdicts, one derivation — see `RequestMatchContext`.
        var context = RequestMatchContext(method: method, url: url.absoluteString)
        // One pass, one allocation. `state.activeRules` would build a second array of
        // every enabled rule before this filter touched it — on every exchange, on the
        // event loop, to produce a result that is usually empty.
        var matched: [TrafficRule] = []
        for rule in state.rules where rule.isEnabled {
            if rule.match.matches(&context, origin: origin) { matched.append(rule) }
        }
        return matched
    }

    static func planRequest(
        state: RulesState,
        method: String,
        url: URL,
        headers: [HeaderPair],
        body: Data?,
        origin: RequestOrigin? = nil
    ) -> RequestPlan {
        planRequest(
            matched: matchingRules(state: state, method: method, url: url, origin: origin),
            method: method, url: url, headers: headers, body: body
        )
    }

    /// Plan from already-matched rules. Matching against the *original* request is
    /// what makes this safe to hand in: the plan's own mutations never feed back
    /// into which rules apply.
    static func planRequest(
        matched: [TrafficRule],
        method: String,
        url: URL,
        headers: [HeaderPair],
        body: Data?
    ) -> RequestPlan {
        var plan = RequestPlan(
            method: method, url: url, headers: headers, body: body,
            shortCircuit: nil, delayMilliseconds: 0, matched: []
        )
        guard !matched.isEmpty else { return plan }
        plan.matched = matched

        for rule in matched {
            let actions = rule.actions
            if let rewrite = actions.rewriteRequest, !rewrite.isEmpty {
                if let newMethod = rewrite.method { plan.method = newMethod.uppercased() }
                if let newURL = rewrite.url.flatMap(URL.init(string:)) {
                    // Whole-URL replacement, unlike mapRemote's origin swap. The Host
                    // header has to follow it or the upstream is asked for one host
                    // under another's name — same reasoning as mapRemote's default.
                    plan.url = newURL
                    plan.headers.removeAll { $0.name.lowercased() == "host" }
                }
                plan.headers = applyHeaderEdits(plan.headers, set: rewrite.setHeaders, remove: rewrite.removeHeaders)
                switch rewrite.body {
                case nil:
                    break
                case let .text(text):
                    // `.text("")` is a body of zero bytes, which is a different
                    // instruction from "leave the body alone" (the nil above).
                    plan.body = Data(text.utf8)
                case let .file(path):
                    if let data = try? Data(contentsOf: URL(fileURLWithPath: path)) {
                        plan.body = data
                    } else {
                        // Read at request time, so this is a live failure, and a
                        // request has no response object to answer on the way
                        // `mapLocal` answers with a 404. The client's own body goes
                        // upstream unchanged; the log line is the only channel.
                        Log.rules.error("""
                        Rule \(rule.name, privacy: .public) could not read request body file \
                        \(path, privacy: .public); the original request body was forwarded instead.
                        """)
                    }
                }
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
                // `targets(header:)` is the model's, not re-derived here: an
                // untargeted substitution still edits every value, a targeted one
                // only its own header — and both sides of the exchange ask the
                // same way.
                plan.headers = plan.headers.map { pair in
                    sub.targets(header: pair.name)
                        ? HeaderPair(name: pair.name, value: sub.apply(to: pair.value))
                        : pair
                }
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
                result.headers = result.headers.map { pair in
                    sub.targets(header: pair.name)
                        ? HeaderPair(name: pair.name, value: sub.apply(to: pair.value))
                        : pair
                }
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
    /// the same composition `ReplayOverrides` uses. A set header lands at the end of
    /// the list, which is what distinguishes this from `BreakpointForwarder`'s
    /// edit-in-place variant; both go through `[HeaderPair]`'s one definition of
    /// header-name equality rather than folding case by hand.
    static func applyHeaderEdits(_ headers: [HeaderPair], set: [HeaderPair], remove: [String]) -> [HeaderPair] {
        var headers = headers
        headers.removeAll(namedAnyOf: remove)
        for header in set {
            headers.removeAll(named: header.name)
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
