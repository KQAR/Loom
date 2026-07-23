import Foundation

// MARK: - Matching

/// What traffic a rule applies to. Matching runs against the *original* client
/// request (before any other rule has rewritten it), so rule order never changes
/// which rules match — only the order their actions apply in.
public struct RuleMatch: Equatable, Codable, Sendable {
    /// Matched against the full request URL (e.g. `https://api.example.com/v1/home?x=1`).
    /// - As a glob (`isRegex == false`): `*` matches any run of characters and the
    ///   pattern must cover the whole URL. A pattern without any `*` is treated as
    ///   a prefix (so `https://api.example.com/v1/home` matches regardless of query).
    /// - As a regex (`isRegex == true`): standard unanchored, case-insensitive search.
    public var urlPattern: String
    public var isRegex: Bool
    /// HTTP methods to match (case-insensitive); empty means all methods.
    public var methods: [String]

    public init(urlPattern: String, isRegex: Bool = false, methods: [String] = []) {
        self.urlPattern = urlPattern
        self.isRegex = isRegex
        self.methods = methods
    }

    public func matches(method: String, url: String) -> Bool {
        if !methods.isEmpty,
           !methods.contains(where: { $0.caseInsensitiveCompare(method) == .orderedSame }) {
            return false
        }
        if isRegex {
            guard let regex = RegexCache.regex(urlPattern, caseInsensitive: true) else {
                return false
            }
            return regex.firstMatch(in: url, range: NSRange(url.startIndex..., in: url)) != nil
        }
        if urlPattern.contains("*") {
            // Same whole-string glob the SSL scope uses; it globs any string, not just hosts.
            return SSLScope.matches(pattern: urlPattern, host: url)
        }
        return url.lowercased().hasPrefix(urlPattern.lowercased())
    }
}

// MARK: - Actions

/// Short-circuit the exchange with a synthesized response; the upstream is never contacted.
public struct MockResponseAction: Equatable, Codable, Sendable {
    public var statusCode: Int
    public var headers: [HeaderPair]
    /// UTF-8 response body.
    public var bodyText: String?
    /// Convenience Content-Type (e.g. `application/json`); merged into `headers`.
    public var contentType: String?

    public init(statusCode: Int = 200, headers: [HeaderPair] = [], bodyText: String? = nil, contentType: String? = nil) {
        self.statusCode = statusCode
        self.headers = headers
        self.bodyText = bodyText
        self.contentType = contentType
    }
}

/// Re-target the request at a different origin, keeping path + query. `destination`
/// is an origin like `http://127.0.0.1:3001` (scheme + host + optional port).
public struct MapRemoteAction: Equatable, Codable, Sendable {
    public var destination: String
    /// Requests whose URL matches this pattern (same glob/regex rules as the rule
    /// matcher — regex when it looks like one) are left un-redirected.
    public var excludePattern: String?
    /// Keep the original `Host` header instead of letting it follow the new origin.
    public var keepHostHeader: Bool

    public init(destination: String, excludePattern: String? = nil, keepHostHeader: Bool = false) {
        self.destination = destination
        self.excludePattern = excludePattern
        self.keepHostHeader = keepHostHeader
    }

    // Tolerant decode: rules saved before these fields existed still load.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        destination = try c.decode(String.self, forKey: .destination)
        excludePattern = try c.decodeIfPresent(String.self, forKey: .excludePattern)
        keepHostHeader = try c.decodeIfPresent(Bool.self, forKey: .keepHostHeader) ?? false
    }
}

/// A whistle-style find/replace applied to one part of the request or response.
/// Unlike a wholesale rewrite, this substitutes matching text in place — the
/// building block of the "modify request"/"modify response" editor segments.
public struct SubstitutionRule: Equatable, Codable, Sendable, Identifiable {
    /// Which part of the message the substitution runs over.
    public enum Field: String, Codable, Sendable, CaseIterable {
        case url      // request line / query params (request side only)
        case header   // header values
        case body     // body text
    }

    public var id: UUID
    public var field: Field
    /// Text (or regex) to find.
    public var match: String
    /// Replacement text (regex backreferences like `$1` allowed when `isRegex`).
    public var replacement: String
    public var isRegex: Bool
    public var caseSensitive: Bool

    public init(
        id: UUID = UUID(),
        field: Field,
        match: String,
        replacement: String,
        isRegex: Bool = false,
        caseSensitive: Bool = false
    ) {
        self.id = id
        self.field = field
        self.match = match
        self.replacement = replacement
        self.isRegex = isRegex
        self.caseSensitive = caseSensitive
    }

    public var isEmpty: Bool { match.isEmpty }

    /// Apply this substitution to a string, returning the result unchanged on a
    /// bad regex so a typo never silently drops the whole body.
    public func apply(to input: String) -> String {
        guard !match.isEmpty else { return input }
        if isRegex {
            guard let regex = RegexCache.regex(match, caseInsensitive: !caseSensitive) else { return input }
            let range = NSRange(input.startIndex..., in: input)
            return regex.stringByReplacingMatches(in: input, range: range, withTemplate: replacement)
        }
        let options: String.CompareOptions = caseSensitive ? [] : [.caseInsensitive]
        return input.replacingOccurrences(of: match, with: replacement, options: options)
    }
}

/// Serve a local file as the response body; the upstream is never contacted.
public struct MapLocalAction: Equatable, Codable, Sendable {
    /// Absolute filesystem path of the file to serve.
    public var path: String
    public var statusCode: Int
    /// Content-Type to serve; when nil a best guess is made from the file extension.
    public var contentType: String?

    public init(path: String, statusCode: Int = 200, contentType: String? = nil) {
        self.path = path
        self.statusCode = statusCode
        self.contentType = contentType
    }
}

/// Mutate the outgoing request before it is forwarded upstream.
public struct RequestRewriteAction: Equatable, Codable, Sendable {
    public var method: String?
    /// Headers to add or overwrite (matched case-insensitively by name).
    public var setHeaders: [HeaderPair]
    /// Header names to remove (matched case-insensitively).
    public var removeHeaders: [String]
    /// Replacement UTF-8 request body.
    public var bodyText: String?

    public init(method: String? = nil, setHeaders: [HeaderPair] = [], removeHeaders: [String] = [], bodyText: String? = nil) {
        self.method = method
        self.setHeaders = setHeaders
        self.removeHeaders = removeHeaders
        self.bodyText = bodyText
    }

    public var isEmpty: Bool {
        method == nil && setHeaders.isEmpty && removeHeaders.isEmpty && bodyText == nil
    }
}

/// Mutate the response (real or mocked) before it is written back to the client.
public struct ResponseRewriteAction: Equatable, Codable, Sendable {
    public var statusCode: Int?
    public var setHeaders: [HeaderPair]
    public var removeHeaders: [String]
    /// Replacement UTF-8 response body.
    public var bodyText: String?

    public init(statusCode: Int? = nil, setHeaders: [HeaderPair] = [], removeHeaders: [String] = [], bodyText: String? = nil) {
        self.statusCode = statusCode
        self.setHeaders = setHeaders
        self.removeHeaders = removeHeaders
        self.bodyText = bodyText
    }

    public var isEmpty: Bool {
        statusCode == nil && setHeaders.isEmpty && removeHeaders.isEmpty && bodyText == nil
    }
}

/// How a matched rule sources its response — the one mutually-exclusive routing
/// decision. Modeling it as a sum type (rather than four independently-settable
/// optionals + a `block` bool) makes illegal combinations like "block AND mock AND
/// mapRemote" unrepresentable, so there's no precedence rule to document or
/// validate for a single rule.
///
/// - `passthrough`: fetch the original upstream (the default).
/// - `mapRemote`: fetch a *different* origin — still an upstream fetch, so it
///   composes with the response modifiers below.
/// - `block` / `mock` / `mapLocal`: short-circuit; the upstream is never contacted.
public enum Route: Equatable, Codable, Sendable {
    case passthrough
    case block
    case mock(MockResponseAction)
    case mapLocal(MapLocalAction)
    case mapRemote(MapRemoteAction)

    private enum CodingKeys: String, CodingKey { case type, mock, mapLocal, mapRemote }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .passthrough: try c.encode("passthrough", forKey: .type)
        case .block: try c.encode("block", forKey: .type)
        case let .mock(m): try c.encode("mock", forKey: .type); try c.encode(m, forKey: .mock)
        case let .mapLocal(l): try c.encode("mapLocal", forKey: .type); try c.encode(l, forKey: .mapLocal)
        case let .mapRemote(r): try c.encode("mapRemote", forKey: .type); try c.encode(r, forKey: .mapRemote)
        }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .type) {
        case "passthrough": self = .passthrough
        case "block": self = .block
        case "mock": self = .mock(try c.decode(MockResponseAction.self, forKey: .mock))
        case "mapLocal": self = .mapLocal(try c.decode(MapLocalAction.self, forKey: .mapLocal))
        case "mapRemote": self = .mapRemote(try c.decode(MapRemoteAction.self, forKey: .mapRemote))
        case let other:
            throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "unknown route \"\(other)\"")
        }
    }
}

/// What a rule does to matching traffic: one `route` (how the response is sourced)
/// plus orthogonal modifiers that compose with it — request/response rewrites,
/// find/replace substitutions, and a response delay. Across several matched rules
/// the engine still resolves route precedence (block > mock > mapLocal), but a
/// single rule can no longer hold conflicting routes.
public struct RuleActions: Equatable, Codable, Sendable {
    public var route: Route
    public var rewriteRequest: RequestRewriteAction?
    public var rewriteResponse: ResponseRewriteAction?
    /// Find/replace substitutions on the outgoing request ("modify request").
    public var requestSubstitutions: [SubstitutionRule]
    /// Find/replace substitutions on the returned response ("modify response").
    public var responseSubstitutions: [SubstitutionRule]
    /// Delay before the response is released to the client (crude throttle).
    public var delayMilliseconds: Int?

    public init(
        route: Route = .passthrough,
        rewriteRequest: RequestRewriteAction? = nil,
        rewriteResponse: ResponseRewriteAction? = nil,
        requestSubstitutions: [SubstitutionRule] = [],
        responseSubstitutions: [SubstitutionRule] = [],
        delayMilliseconds: Int? = nil
    ) {
        self.route = route
        self.rewriteRequest = rewriteRequest
        self.rewriteResponse = rewriteResponse
        self.requestSubstitutions = requestSubstitutions
        self.responseSubstitutions = responseSubstitutions
        self.delayMilliseconds = delayMilliseconds
    }

    // Tolerant decode: a missing route defaults to passthrough.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        route = try c.decodeIfPresent(Route.self, forKey: .route) ?? .passthrough
        rewriteRequest = try c.decodeIfPresent(RequestRewriteAction.self, forKey: .rewriteRequest)
        rewriteResponse = try c.decodeIfPresent(ResponseRewriteAction.self, forKey: .rewriteResponse)
        requestSubstitutions = try c.decodeIfPresent([SubstitutionRule].self, forKey: .requestSubstitutions) ?? []
        responseSubstitutions = try c.decodeIfPresent([SubstitutionRule].self, forKey: .responseSubstitutions) ?? []
        delayMilliseconds = try c.decodeIfPresent(Int.self, forKey: .delayMilliseconds)
    }

    /// Substitutions that actually carry a match string (empty rows are ignored).
    public var activeRequestSubstitutions: [SubstitutionRule] { requestSubstitutions.filter { !$0.isEmpty } }
    public var activeResponseSubstitutions: [SubstitutionRule] { responseSubstitutions.filter { !$0.isEmpty } }

    public var isEmpty: Bool {
        guard case .passthrough = route else { return false }
        return (rewriteRequest?.isEmpty ?? true) && (rewriteResponse?.isEmpty ?? true)
            && activeRequestSubstitutions.isEmpty && activeResponseSubstitutions.isEmpty
            && delayMilliseconds == nil
    }
}

// MARK: - Rule

/// One traffic rule: a matcher plus the actions to apply. Rules are evaluated in
/// list order; every enabled rule whose matcher hits contributes its actions.
public struct TrafficRule: Equatable, Codable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    public var comment: String?
    /// Optional group label (e.g. one group per debugging scenario). Grouping is
    /// organizational — evaluation order stays the flat list order — but a whole
    /// group can be enabled/disabled at once.
    public var group: String?
    public var isEnabled: Bool
    public var match: RuleMatch
    public var actions: RuleActions
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        name: String,
        comment: String? = nil,
        group: String? = nil,
        isEnabled: Bool = true,
        match: RuleMatch,
        actions: RuleActions,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.comment = comment
        self.group = group
        self.isEnabled = isEnabled
        self.match = match
        self.actions = actions
        self.createdAt = createdAt
    }

    /// Human-readable reason this rule is malformed, or nil when it is valid.
    /// Checked on create/update so a broken rule is refused with a structured
    /// error instead of silently never matching.
    public func validationError() -> String? {
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "rule name must not be empty"
        }
        if match.urlPattern.isEmpty {
            return "match.urlPattern must not be empty"
        }
        if match.isRegex, (try? NSRegularExpression(pattern: match.urlPattern)) == nil {
            return "match.urlPattern is not a valid regular expression"
        }
        if actions.isEmpty {
            return "rule has no actions — set a route (block/mock/mapRemote/mapLocal) or a rewrite/substitution/delay"
        }
        switch actions.route {
        case .passthrough:
            break
        case .block:
            break
        case let .mapRemote(map):
            guard let url = URL(string: map.destination), url.scheme != nil, url.host != nil else {
                return "mapRemote.destination must be an origin like http://127.0.0.1:3001"
            }
        case let .mapLocal(local):
            if !local.path.hasPrefix("/") { return "mapLocal.path must be an absolute file path" }
        case let .mock(mock):
            if !(100...599).contains(mock.statusCode) { return "mockResponse.statusCode must be a valid HTTP status" }
        }
        if let delay = actions.delayMilliseconds, delay < 0 {
            return "delayMilliseconds must be >= 0"
        }
        for sub in actions.activeRequestSubstitutions + actions.activeResponseSubstitutions where sub.isRegex {
            if (try? NSRegularExpression(pattern: sub.match)) == nil {
                return "substitution match \"\(sub.match)\" is not a valid regular expression"
            }
        }
        return nil
    }
}

/// The whole rules configuration: a master switch plus the ordered rule list.
public struct RulesState: Equatable, Codable, Sendable {
    /// Master switch; when false no rule is applied regardless of per-rule flags.
    public var enabled: Bool
    public var rules: [TrafficRule]

    public init(enabled: Bool = true, rules: [TrafficRule] = []) {
        self.enabled = enabled
        self.rules = rules
    }

    /// Rules that would currently apply to traffic, in evaluation order.
    public var activeRules: [TrafficRule] {
        enabled ? rules.filter(\.isEnabled) : []
    }
}

// MARK: - Engine surface

/// The rules surface of the engine — CRUD over `TrafficRule`s plus the master
/// switch. Composed into `ProxyControlling` so the MCP server and the TCA client
/// mutate the same rule set through the one shared engine.
public protocol RulesControlling: Sendable {
    func rulesState() async -> RulesState
    func setRulesEnabled(_ enabled: Bool) async
    /// Validates and appends a rule; throws `ProxyControlError.invalidRule`.
    func addRule(_ rule: TrafficRule) async throws
    /// Replaces the rule with the same id; throws when unknown or invalid.
    func updateRule(_ rule: TrafficRule) async throws
    func deleteRule(id: UUID) async throws
    /// Enable/disable every rule in a group at once (`nil` = the ungrouped rules).
    func setGroupEnabled(group: String?, enabled: Bool) async
}

// MARK: - Pattern matching

/// Memoized `NSRegularExpression` compilation. The rule matcher and substitutions
/// run on every request; compiling the same pattern each time is wasteful, so
/// cache by (pattern, case-sensitivity). Thread-safe: matching happens on NIO
/// event loops and async tasks alike.
public enum RegexCache {
    private struct Key: Hashable { let pattern: String; let caseInsensitive: Bool }
    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: [Key: NSRegularExpression] = [:]

    /// The compiled regex for `pattern`, or nil if it doesn't compile (invalid
    /// patterns are rejected at rule-creation time, so this is rare).
    public static func regex(_ pattern: String, caseInsensitive: Bool = true) -> NSRegularExpression? {
        let key = Key(pattern: pattern, caseInsensitive: caseInsensitive)
        lock.lock()
        defer { lock.unlock() }
        if let cached = cache[key] { return cached }
        let options: NSRegularExpression.Options = caseInsensitive ? [.caseInsensitive] : []
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return nil }
        cache[key] = regex
        return regex
    }
}

/// One definition of a loose (flag-free) URL match: treat the pattern as a regex
/// when it compiles and hits, else fall back to the whole-string glob/prefix the
/// SSL scope uses. Shared by mapRemote's `excludePattern` so the "is this URL
/// excluded" heuristic lives in exactly one place.
public enum Pattern {
    public static func matchesLoosely(_ pattern: String, _ string: String) -> Bool {
        guard !pattern.isEmpty else { return false }
        if let regex = RegexCache.regex(pattern, caseInsensitive: true),
           regex.firstMatch(in: string, range: NSRange(string.startIndex..., in: string)) != nil {
            return true
        }
        return SSLScope.matches(pattern: pattern, host: string)
    }
}
