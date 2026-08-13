import Foundation
import Synchronization

// MARK: - Matching

/// How `RuleMatch.urlPattern` is compared against the request URL.
///
/// One enum rather than the `isRegex` + `isExact` pair it replaces. Two booleans
/// have four combinations for three states, so `isRegex && isExact` was
/// representable and had to be resolved by a precedence rule written in prose
/// (the matcher checked regex first; the editor cleared one when the other was
/// set). Same defect the `Route` sum type was introduced to fix, one level down.
///
/// It also makes the fourth state sayable. Glob vs prefix used to be inferred
/// from *whether the pattern contained a `*`*, so a URL with a literal `*` in it
/// could not be prefix-matched at all. `inferred(for:)` still does that inference
/// — but only where it belongs, at the authoring boundary, and once.
public enum MatchStyle: String, Codable, Sendable, CaseIterable {
    /// `urlPattern` must be a case-insensitive prefix of the URL, so a pattern
    /// without a query string still matches every query string. The default a
    /// human means when they paste a URL.
    case prefix
    /// `*` matches any run of characters and the pattern must cover the whole URL.
    case glob
    /// The URL must equal `urlPattern` exactly.
    case exact
    /// Unanchored, case-insensitive regular expression.
    case regex

    /// What a caller means by a bare pattern: `*` in it reads as a glob, anything
    /// else as a prefix. The one implementation of an inference the model no
    /// longer performs implicitly.
    public static func inferred(for pattern: String) -> MatchStyle {
        pattern.utf8.contains(UInt8(ascii: "*")) ? .glob : .prefix
    }
}

/// What one query parameter must look like for a rule to match.
///
/// Two cases rather than a `String` with `*` meaning "any value". The sentinel
/// read fine until you needed the thing it stood for: a parameter whose value is
/// literally `*` could not be required, because the value space and the
/// "any value" marker shared it. Same class of defect as `MatchStyle`'s boolean
/// pair — one field carrying two kinds of fact.
public enum QueryPredicate: Equatable, Hashable, Sendable {
    /// The parameter must be present and equal this value.
    case equals(String)
    /// The parameter must be present, with any value.
    case present

    /// The legacy wire/file spelling, where `*` means `present` — `nil` when the
    /// predicate cannot be said that way (`equals("*")`, the state the sentinel
    /// made unreachable).
    var legacyWireValue: String? {
        switch self {
        case .present: return "*"
        case let .equals(value): return value == "*" ? nil : value
        }
    }

    /// Parse the legacy spelling.
    public init(legacyWireValue value: String) {
        self = value == "*" ? .present : .equals(value)
    }
}

/// What traffic a rule applies to. Matching runs against the *original* client
/// request (before any other rule has rewritten it), so rule order never changes
/// which rules match — only the order their actions apply in.
public struct RuleMatch: Equatable, Codable, Sendable {
    /// Matched against the full request URL (e.g. `https://api.example.com/v1/home?x=1`),
    /// the way `style` says.
    public var urlPattern: String
    /// How `urlPattern` is compared. See `MatchStyle`.
    public var style: MatchStyle
    /// HTTP methods to match (case-insensitive); empty means all methods.
    public var methods: [String]
    /// Optional host predicate as a glob (`*.example.com`), matched against the
    /// URL's host. nil/empty = any host.
    public var hostPattern: String?
    /// Optional query predicates: each key must satisfy its `QueryPredicate`.
    /// nil/empty = no query constraint. Order-independent, unlike encoding the
    /// query into `urlPattern`.
    public var query: [String: QueryPredicate]?
    /// Optional originating-app predicate: bundle id or display name, compared
    /// case-insensitively (same vocabulary as `FlowQuery.sourceApp`). This is what
    /// makes "mock it for my app only, leave the browser alone" expressible.
    ///
    /// **Fails closed.** Traffic Loom couldn't attribute to *any* app does not match
    /// an app-scoped rule. A rule that says "only this app" must never leak onto
    /// traffic that might be another.
    ///
    /// A LAN device's traffic *is* in scope: it has no local pid, so its app comes
    /// from the request's `User-Agent` (`SourceApp.attribution == .userAgent`) —
    /// a claim by the client rather than a fact about a socket, and spoofable.
    /// Matching does not distinguish the two, because a rule scoped to a phone's
    /// app that silently matched nothing was the worse failure; read
    /// `sourceApp.attribution` on a flow when it matters which one is in hand.
    public var sourceApp: String?
    /// Optional originating-device predicate: the remote IP as seen by the proxy
    /// (`SourceDevice.groupingKey`, from `list_devices`). Also fails closed.
    public var deviceIP: String?

    /// - Parameter style: omit to let the pattern speak for itself
    ///   (`MatchStyle.inferred(for:)` — `*` means glob, otherwise prefix), which is
    ///   what a caller pasting a URL means.
    public init(
        urlPattern: String,
        style: MatchStyle? = nil,
        methods: [String] = [],
        hostPattern: String? = nil,
        query: [String: QueryPredicate]? = nil,
        sourceApp: String? = nil,
        deviceIP: String? = nil
    ) {
        self.urlPattern = urlPattern
        self.style = style ?? .inferred(for: urlPattern)
        self.methods = methods
        self.hostPattern = hostPattern
        self.query = query
        self.sourceApp = sourceApp
        self.deviceIP = deviceIP
    }

    /// True when the pattern is a regular expression / an exact URL. Read-only
    /// projections of `style`, kept because "is this a regex" is a question three
    /// surfaces ask and none of them should re-derive it.
    public var isRegex: Bool { style == .regex }
    public var isExact: Bool { style == .exact }

    /// True when this match constrains *who* made the request, so a caller with no
    /// origin information knows it cannot evaluate the rule faithfully.
    public var constrainsOrigin: Bool {
        !(sourceApp ?? "").isEmpty || !(deviceIP ?? "").isEmpty
    }

    private enum CodingKeys: String, CodingKey {
        case urlPattern, style, methods, hostPattern, query, sourceApp, deviceIP
        // Read-only: the shape rules were saved in before `style` existed.
        case isRegex, isExact
    }

    // Tolerant decode: rules saved before these fields existed still load, and a
    // rules file written by an older build carries the two booleans instead of a
    // style — mapped here, once, with the same precedence the old matcher used
    // (regex beat exact) and the same `*` inference it applied to the rest.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        urlPattern = try c.decode(String.self, forKey: .urlPattern)
        if let style = try c.decodeIfPresent(MatchStyle.self, forKey: .style) {
            self.style = style
        } else if try c.decodeIfPresent(Bool.self, forKey: .isRegex) == true {
            style = .regex
        } else if try c.decodeIfPresent(Bool.self, forKey: .isExact) == true {
            style = .exact
        } else {
            style = .inferred(for: urlPattern)
        }
        methods = try c.decodeIfPresent([String].self, forKey: .methods) ?? []
        hostPattern = try c.decodeIfPresent(String.self, forKey: .hostPattern)
        query = try Self.decodeQuery(from: c)
        sourceApp = try c.decodeIfPresent(String.self, forKey: .sourceApp)
        deviceIP = try c.decodeIfPresent(String.self, forKey: .deviceIP)
    }

    /// Writes `style`, never the two legacy booleans — they are decode-only, so a
    /// file that has been through this build says which of the four styles it means
    /// rather than leaving `glob` vs `prefix` to be re-inferred on every load.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(urlPattern, forKey: .urlPattern)
        try c.encode(style, forKey: .style)
        try c.encode(methods, forKey: .methods)
        try c.encodeIfPresent(hostPattern, forKey: .hostPattern)
        try Self.encodeQuery(query, to: &c)
        try c.encodeIfPresent(sourceApp, forKey: .sourceApp)
        try c.encodeIfPresent(deviceIP, forKey: .deviceIP)
    }

    /// Does this request match?
    ///
    /// `origin` is who made it (local app / device). Pass it wherever it is known —
    /// omitting it on a rule that constrains the origin means the rule cannot match,
    /// by design: an app-scoped rule that applied to unattributed traffic would be
    /// acting on requests that might be a different app's.
    ///
    /// **A caller matching several rules against one request must not use this** —
    /// it builds a fresh `RequestMatchContext` every time, which re-parses the URL
    /// (`URLComponents`) and re-encodes it for every rule in the list. Build one
    /// context and pass it to `matches(_:origin:)` instead; that is what
    /// `RuleEngine.matchingRules` and `BreakpointStore.firstMatch` do.
    public func matches(method: String, url: String, origin: RequestOrigin? = nil) -> Bool {
        var context = RequestMatchContext(method: method, url: url)
        return matches(&context, origin: origin)
    }

    /// Does this request match, against a context shared by every rule in one
    /// evaluation? `inout` because the context parses the URL lazily and keeps the
    /// result: the first rule with a `hostPattern` or a `query` pays for the parse
    /// and the rest read it.
    public func matches(_ context: inout RequestMatchContext, origin: RequestOrigin? = nil) -> Bool {
        if !matchesOrigin(origin) { return false }
        if !methods.isEmpty,
           !methods.contains(where: { $0.caseInsensitiveCompare(context.method) == .orderedSame }) {
            return false
        }
        // Host / query predicates run off the parsed URL, so they compose with any
        // urlPattern style without the caller hand-anchoring a regex.
        if let hostPattern, !hostPattern.isEmpty {
            guard Glob.matches(hostPattern, context.host ?? "") else { return false }
        }
        if let query, !query.isEmpty {
            let actual = context.queryItems
            for (key, predicate) in query {
                switch predicate {
                case .present:
                    if actual[key] == nil { return false }
                case let .equals(value):
                    if actual[key] != value { return false }
                }
            }
        }
        let url = context.url
        // One switch, no precedence: the style says which comparison runs, and the
        // "does it contain a `*`" test that used to decide two of these at match
        // time now happens once, when the pattern is authored.
        switch style {
        case .regex:
            guard let regex = RegexCache.regex(urlPattern, caseInsensitive: true) else {
                return false
            }
            return regex.firstMatch(in: url, range: NSRange(url.startIndex..., in: url)) != nil
        case .exact:
            return url.caseInsensitiveCompare(urlPattern) == .orderedSame
        case .glob:
            // Same whole-string glob the SSL scope uses; it globs any string, not just hosts.
            // A glob over the whole URL, which is why the matcher is no longer named
            // after hosts.
            let pattern = Glob.pattern(for: urlPattern)
            // The context encoded the URL's bytes once for the whole rule list; the
            // pattern says whether it can use them (ASCII on both sides) and the
            // string form is the fallback, so the answer is the same either way.
            if let asciiURL = context.asciiURL, let verdict = pattern.matches(asciiBytes: asciiURL) {
                return verdict
            }
            return pattern.matches(url)
        case .prefix:
            return Self.hasCaseInsensitivePrefix(url, urlPattern)
        }
    }

    /// The query map's file/wire shape.
    ///
    /// Legacy (and still what gets written whenever it can be): a plain
    /// `{"key": "value"}` object with `*` meaning "any value". A predicate that
    /// spelling cannot express — `equals("*")`, the one the sentinel used to
    /// swallow — forces the whole map into the explicit form
    /// `{"key": {"equals": "*"}}`. Grow the format only where it has to grow, so
    /// every rules file written before this still round-trips byte-identically.
    private struct QueryPredicateWire: Codable {
        var equals: String?
        var present: Bool?
    }

    private static func decodeQuery(
        from container: KeyedDecodingContainer<CodingKeys>
    ) throws -> [String: QueryPredicate]? {
        if let legacy = try? container.decode([String: String].self, forKey: .query) {
            return legacy.mapValues { QueryPredicate(legacyWireValue: $0) }
        }
        guard let explicit = try container.decodeIfPresent([String: QueryPredicateWire].self, forKey: .query)
        else { return nil }
        return explicit.mapValues { wire in
            if let equals = wire.equals { return .equals(equals) }
            return .present
        }
    }

    private static func encodeQuery(
        _ query: [String: QueryPredicate]?,
        to container: inout KeyedEncodingContainer<CodingKeys>
    ) throws {
        guard let query, !query.isEmpty else { return }
        var legacy: [String: String] = [:]
        for (key, predicate) in query {
            guard let value = predicate.legacyWireValue else { legacy = [:]; break }
            legacy[key] = value
        }
        if legacy.count == query.count {
            try container.encode(legacy, forKey: .query)
            return
        }
        try container.encode(query.mapValues { predicate -> QueryPredicateWire in
            switch predicate {
            case let .equals(value): return QueryPredicateWire(equals: value, present: nil)
            case .present: return QueryPredicateWire(equals: nil, present: true)
            }
        }, forKey: .query)
    }

    /// Prefix match, case-insensitive, without lowercasing either side.
    ///
    /// This is the default (and most common) `urlPattern` style, so it runs once per
    /// rule per exchange on the event loop. `url.lowercased().hasPrefix(pattern.lowercased())`
    /// allocated two whole strings each time — measured at 21.5 µs per request for 20
    /// non-matching rules, most of it here. The ASCII fast path costs no allocation at
    /// all and covers every URL that isn't punycode/percent-escaped; the fallback keeps
    /// those correct.
    static func hasCaseInsensitivePrefix(_ url: String, _ prefix: String) -> Bool {
        var haystack = url.utf8.makeIterator()
        for expected in prefix.utf8 {
            guard let actual = haystack.next() else { return false }
            if actual == expected { continue }
            // ASCII case fold, both directions. Non-ASCII bytes never fold here — they
            // fall through to the unequal return, and the caller's pattern would have to
            // match them byte-for-byte, which is what the exact/glob styles are for.
            guard actual | 0x20 == expected | 0x20,
                  (actual | 0x20) >= 0x61, (actual | 0x20) <= 0x7A
            else { return false }
        }
        return true
    }

    private func matchesOrigin(_ origin: RequestOrigin?) -> Bool {
        if let sourceApp, !sourceApp.isEmpty {
            guard let app = origin?.app,
                  app.groupingKey.caseInsensitiveCompare(sourceApp) == .orderedSame
                  || app.name.caseInsensitiveCompare(sourceApp) == .orderedSame
            else { return false }
        }
        if let deviceIP, !deviceIP.isEmpty {
            guard origin?.device?.groupingKey == deviceIP else { return false }
        }
        return true
    }

    static func queryItems(_ components: URLComponents?) -> [String: String] {
        var result: [String: String] = [:]
        for item in components?.queryItems ?? [] {
            result[item.name] = item.value ?? ""
        }
        return result
    }
}

/// One request, prepared once for a whole list of rule predicates.
///
/// Every rule in the list is matched against the *same* method and URL, so anything
/// derived from them is per-request work that was being paid per rule: `URLComponents`
/// parsed the URL again for every rule carrying a `hostPattern` or a `query`, and the
/// glob path re-encoded the URL to bytes for every rule. With 50 rules that is 50
/// parses and 50 encodings of one string, on the event loop, per exchange.
///
/// Both derivations are lazy: a rule list with no host/query predicate never parses,
/// and a list with no glob rule never encodes.
public struct RequestMatchContext {
    public let method: String
    public let url: String

    private var parsedComponents = false
    private var components: URLComponents?
    private var parsedQueryItems: [String: String]?
    private var encodedURL = false
    private var encodedBytes: [UInt8]?

    public init(method: String, url: String) {
        self.method = method
        self.url = url
    }

    /// The URL's bytes when it is pure ASCII (the overwhelmingly common case — a URL
    /// on the wire is percent-encoded and punycoded), for `Glob.Pattern`'s byte path.
    /// Nil for a non-ASCII URL, which sends every pattern down the `String` path and
    /// its Unicode-correct case folding.
    ///
    /// Derived on first ask, not in `init`: a rule list with no glob rule never needs
    /// it, and encoding it eagerly made the prefix and exact styles measurably slower
    /// (8.7 ms against 5.3 ms per 1 000 requests at 50 rules) for a value they never
    /// read.
    public var asciiURL: [UInt8]? {
        mutating get {
            if encodedURL { return encodedBytes }
            encodedURL = true
            var url = url
            encodedBytes = url.withUTF8 { buffer -> [UInt8]? in
                for byte in buffer where byte >= 0x80 { return nil }
                return Array(buffer)
            }
            return encodedBytes
        }
    }

    /// The URL's host as `URLComponents` reads it — the same value the per-rule parse
    /// produced, so a host predicate's verdict is unchanged.
    public var host: String? {
        mutating get { parse()?.host }
    }

    public var queryItems: [String: String] {
        mutating get {
            if let parsedQueryItems { return parsedQueryItems }
            let items = RuleMatch.queryItems(parse())
            parsedQueryItems = items
            return items
        }
    }

    private mutating func parse() -> URLComponents? {
        if parsedComponents { return components }
        parsedComponents = true
        components = URLComponents(string: url)
        return components
    }
}

// MARK: - Actions

/// A mocked response body: text, or bytes that aren't text.
///
/// One value rather than the `bodyText` + `bodyBase64` pair it replaces, for the
/// same reason as `MatchStyle`: both could be set at once, and which one won was
/// a sentence in a doc comment (`resolvedBody`) plus a `Bool` in the editor
/// keeping them apart. A mock has one body.
public enum MockBody: Equatable, Sendable {
    case text(String)
    /// For binary payloads that aren't valid UTF-8 (images, protobuf, gzip).
    case bytes(Data)

    public var data: Data {
        switch self {
        case let .text(text): return Data(text.utf8)
        case let .bytes(data): return data
        }
    }
}

/// Short-circuit the exchange with a synthesized response; the upstream is never contacted.
public struct MockResponseAction: Equatable, Codable, Sendable {
    public var statusCode: Int
    public var headers: [HeaderPair]
    public var body: MockBody?
    /// Convenience Content-Type (e.g. `application/json`); merged into `headers`,
    /// which **win** — an explicit `Content-Type` in `headers` is never overwritten
    /// by this (see `RuleApplyingForwarder.synthesize`).
    public var contentType: String?

    public init(
        statusCode: Int = 200,
        headers: [HeaderPair] = [],
        body: MockBody? = nil,
        contentType: String? = nil
    ) {
        self.statusCode = statusCode
        self.headers = headers
        self.body = body
        self.contentType = contentType
    }

    /// The wire shape, where both a text body and a base64 body can arrive in one
    /// object (`set_rule`'s `body` / `body_base64`). The precedence — base64 wins —
    /// lives here, at the one boundary that can receive both, instead of in the
    /// model where it was an illegal state waiting to be resolved.
    public static func fromWire(
        statusCode: Int = 200,
        headers: [HeaderPair] = [],
        bodyText: String? = nil,
        bodyBase64: String? = nil,
        contentType: String? = nil
    ) -> MockResponseAction {
        let body: MockBody?
        if let bodyBase64 {
            // An unparseable base64 body stays *declared* rather than silently
            // becoming text: `resolvedBody()` sends empty, and `validationError()`
            // is what refuses it at the door.
            body = .bytes(Data(base64Encoded: bodyBase64) ?? Data())
        } else if let bodyText {
            body = .text(bodyText)
        } else {
            body = nil
        }
        return MockResponseAction(statusCode: statusCode, headers: headers, body: body, contentType: contentType)
    }

    /// The body as text, or nil when it is binary — for a surface that shows text.
    public var bodyText: String? {
        if case let .text(text) = body { return text }
        return nil
    }

    /// The body as base64, or nil when it is text — for the wire and for surfaces
    /// that offer a binary editor.
    public var bodyBase64: String? {
        if case let .bytes(data) = body { return data.base64EncodedString() }
        return nil
    }

    /// The file/wire encoding is deliberately **unchanged** — still `bodyText` /
    /// `bodyBase64` keys — so a rules file written by any version still loads in
    /// any other. The sum type is what the code holds, not what the JSON says.
    private enum CodingKeys: String, CodingKey {
        case statusCode, headers, bodyText, bodyBase64, contentType
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self = MockResponseAction.fromWire(
            statusCode: try c.decodeIfPresent(Int.self, forKey: .statusCode) ?? 200,
            headers: try c.decodeIfPresent([HeaderPair].self, forKey: .headers) ?? [],
            bodyText: try c.decodeIfPresent(String.self, forKey: .bodyText),
            bodyBase64: try c.decodeIfPresent(String.self, forKey: .bodyBase64),
            contentType: try c.decodeIfPresent(String.self, forKey: .contentType)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(statusCode, forKey: .statusCode)
        try c.encode(headers, forKey: .headers)
        try c.encodeIfPresent(bodyText, forKey: .bodyText)
        try c.encodeIfPresent(bodyBase64, forKey: .bodyBase64)
        try c.encodeIfPresent(contentType, forKey: .contentType)
    }

    /// The response body bytes; empty when the mock has no body.
    public func resolvedBody() -> Data { body?.data ?? Data() }
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
    ///
    /// `header` carries its target because the untargeted version — replace this
    /// text in *every* header value — was the only header substitution available,
    /// and it is the wrong tool for the common case. "Rewrite `X-Token`'s value"
    /// had to be expressed either as a blunt search across every header (which
    /// hits any other header containing the same text) or as a whole-header
    /// overwrite via `rewriteRequest.setHeaders` (which needs the new value in
    /// full). The middle — address one header, edit its value — had no
    /// representation at all.
    public enum Field: Equatable, Hashable, Sendable {
        /// Request line / query params (request side only).
        case url
        /// Header values. `name == nil` keeps the original behaviour: every
        /// header's value. A name (matched case-insensitively) narrows it to one.
        case header(name: String? = nil)
        /// Body text.
        case body

        /// Which of the three it is, ignoring the target — the vocabulary the
        /// wire, the render and the editor's picker all speak.
        public enum Kind: String, Codable, Sendable, CaseIterable {
            case url, header, body
        }

        public var kind: Kind {
            switch self {
            case .url: return .url
            case .header: return .header
            case .body: return .body
            }
        }

        /// The header this targets, or nil for "every header" / a non-header field.
        public var headerName: String? {
            if case let .header(name) = self { return name }
            return nil
        }

        public init(kind: Kind, headerName: String? = nil) {
            switch kind {
            case .url: self = .url
            case .header: self = .header(name: headerName.flatMap { $0.isEmpty ? nil : $0 })
            case .body: self = .body
            }
        }
    }

    public var id: UUID
    public var field: Field
    /// Text (or regex) to find.
    public var match: String
    /// Replacement text (regex backreferences like `$1` allowed when `isRegex`).
    public var replacement: String
    public var isRegex: Bool
    public var caseSensitive: Bool

    /// A `field` that is a bare string ("url"/"header"/"body") is how every
    /// substitution was written before headers could be targeted, so it decodes
    /// as the untargeted form; a targeted one is an object. Encoding keeps the
    /// string whenever there is no target, so an existing rules file round-trips
    /// byte-identically.
    private enum FieldCodingKeys: String, CodingKey { case kind, headerName }

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

    private enum CodingKeys: String, CodingKey {
        case id, field, match, replacement, isRegex, caseSensitive
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        if let bare = try? c.decode(Field.Kind.self, forKey: .field) {
            field = Field(kind: bare)
        } else {
            let f = try c.nestedContainer(keyedBy: FieldCodingKeys.self, forKey: .field)
            field = Field(
                kind: try f.decode(Field.Kind.self, forKey: .kind),
                headerName: try f.decodeIfPresent(String.self, forKey: .headerName)
            )
        }
        match = try c.decode(String.self, forKey: .match)
        replacement = try c.decodeIfPresent(String.self, forKey: .replacement) ?? ""
        isRegex = try c.decodeIfPresent(Bool.self, forKey: .isRegex) ?? false
        caseSensitive = try c.decodeIfPresent(Bool.self, forKey: .caseSensitive) ?? false
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        if let name = field.headerName {
            var f = c.nestedContainer(keyedBy: FieldCodingKeys.self, forKey: .field)
            try f.encode(field.kind, forKey: .kind)
            try f.encode(name, forKey: .headerName)
        } else {
            try c.encode(field.kind, forKey: .field)
        }
        try c.encode(match, forKey: .match)
        try c.encode(replacement, forKey: .replacement)
        try c.encode(isRegex, forKey: .isRegex)
        try c.encode(caseSensitive, forKey: .caseSensitive)
    }

    public var isEmpty: Bool { match.isEmpty }

    /// Whether this substitution applies to a header called `name`. One
    /// definition, because the request side and the response side both ask.
    public func targets(header name: String) -> Bool {
        guard case let .header(target) = field else { return false }
        guard let target, !target.isEmpty else { return true }
        return target.caseInsensitiveCompare(name) == .orderedSame
    }

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

/// Where a replacement request body comes from.
///
/// A sum type for the same reason `MockBody` is one: "inline text" and "this
/// file" are alternatives, and two optional fields would let a rule declare both
/// and need a precedence rule to settle it. `.text("")` is how "replace the body
/// with nothing" is said — distinct from no body rewrite at all, which is the
/// enclosing optional being nil.
public enum RewriteBody: Equatable, Sendable {
    case text(String)
    /// An absolute path, read **at request time** (same as `MapLocalAction`), so
    /// editing the fixture doesn't mean re-writing the rule.
    ///
    /// If the file can't be read the body is left **unchanged** and the failure is
    /// logged at error level (`Log.rules`) — stated here because it is the one
    /// place this type is quiet: a request has no response object to carry the
    /// fault back on, the way `mapLocal` answers an unreadable file with a 404.
    case file(path: String)
}

/// Mutate the outgoing request before it is forwarded upstream.
public struct RequestRewriteAction: Equatable, Codable, Sendable {
    public var method: String?
    /// Replacement request URL, whole. `nil` keeps the client's.
    ///
    /// Distinct from `MapRemoteAction`, which swaps the origin and keeps the path
    /// + query: this sets the lot. Before it existed the request line was only
    /// half-editable from a rule — the method could be set, the URL could only be
    /// text-substituted or origin-mapped.
    public var url: String?
    /// Headers to add or overwrite (matched case-insensitively by name).
    public var setHeaders: [HeaderPair]
    /// Header names to remove (matched case-insensitively).
    public var removeHeaders: [String]
    /// Replacement request body; `nil` leaves the client's body alone.
    public var body: RewriteBody?

    public init(
        method: String? = nil,
        url: String? = nil,
        setHeaders: [HeaderPair] = [],
        removeHeaders: [String] = [],
        body: RewriteBody? = nil
    ) {
        self.method = method
        self.url = url
        self.setHeaders = setHeaders
        self.removeHeaders = removeHeaders
        self.body = body
    }

    /// The inline body text, or nil when the body comes from a file / isn't set.
    public var bodyText: String? {
        if case let .text(text) = body { return text }
        return nil
    }

    /// The body file's path, or nil when the body is inline / isn't set.
    public var bodyFile: String? {
        if case let .file(path) = body { return path }
        return nil
    }

    public var isEmpty: Bool {
        method == nil && url == nil && setHeaders.isEmpty && removeHeaders.isEmpty && body == nil
    }

    /// The file shape keeps the flat keys (`bodyText`, plus `bodyFile`), so a
    /// rules file written before this still loads and one written after it stays
    /// readable as plain JSON.
    private enum CodingKeys: String, CodingKey {
        case method, url, setHeaders, removeHeaders, bodyText, bodyFile
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        method = try c.decodeIfPresent(String.self, forKey: .method)
        url = try c.decodeIfPresent(String.self, forKey: .url)
        setHeaders = try c.decodeIfPresent([HeaderPair].self, forKey: .setHeaders) ?? []
        removeHeaders = try c.decodeIfPresent([String].self, forKey: .removeHeaders) ?? []
        if let path = try c.decodeIfPresent(String.self, forKey: .bodyFile) {
            body = .file(path: path)
        } else if let text = try c.decodeIfPresent(String.self, forKey: .bodyText) {
            body = .text(text)
        } else {
            body = nil
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(method, forKey: .method)
        try c.encodeIfPresent(url, forKey: .url)
        try c.encode(setHeaders, forKey: .setHeaders)
        try c.encode(removeHeaders, forKey: .removeHeaders)
        try c.encodeIfPresent(bodyText, forKey: .bodyText)
        try c.encodeIfPresent(bodyFile, forKey: .bodyFile)
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
        if let rewrite = actions.rewriteRequest {
            if let url = rewrite.url, URL(string: url) == nil || URL(string: url)?.scheme == nil {
                return "rewriteRequest.url must be an absolute URL like https://api.example.com/v1/home"
            }
            if case let .file(path) = rewrite.body, !path.hasPrefix("/") {
                return "rewriteRequest.bodyFile must be an absolute file path"
            }
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
            // No base64 check any more: `MockBody` holds decoded bytes, so an
            // undecodable payload cannot reach the model. It is refused at the two
            // boundaries that can receive one — the MCP codec and the editor —
            // where the offending string still exists to name.
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

/// The whole rules configuration: a master switch, the groups switched off as a
/// unit, and the ordered rule list.
public struct RulesState: Equatable, Codable, Sendable {
    /// Master switch; when false no rule is applied regardless of per-rule flags.
    public var enabled: Bool
    public var rules: [TrafficRule]
    /// Groups currently switched off as a unit — `nil` is the ungrouped bucket,
    /// which the UI toggles like any other group.
    ///
    /// **A third switch rather than a batch write, and that is the point.** Group
    /// disable used to write `isEnabled = false` onto every member, so a group
    /// with one deliberately-off rule came back with that rule *on* after a
    /// disable→enable round trip: the human's "not this one" was overwritten by a
    /// scenario switch, unrecoverably, and scenario switching is the whole reason
    /// groups exist. Kept as its own axis, the two facts compose instead
    /// (`activeRules`) and neither can destroy the other.
    public var disabledGroups: Set<String?>

    public init(enabled: Bool = true, rules: [TrafficRule] = [], disabledGroups: Set<String?> = []) {
        self.enabled = enabled
        self.rules = rules
        self.disabledGroups = disabledGroups
    }

    // Tolerant decode: a rules file written before groups had a state of their own
    // still loads (as "no group is switched off").
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        rules = try c.decodeIfPresent([TrafficRule].self, forKey: .rules) ?? []
        disabledGroups = try c.decodeIfPresent(Set<String?>.self, forKey: .disabledGroups) ?? []
    }

    /// Rules that would currently apply to traffic, in evaluation order — the
    /// three switches ANDed: master, group, rule.
    public var activeRules: [TrafficRule] {
        guard enabled else { return [] }
        return rules.filter { $0.isEnabled && !disabledGroups.contains($0.group) }
    }

    /// Whether a group's switch is on. `nil` = the ungrouped bucket.
    public func isGroupEnabled(_ group: String?) -> Bool {
        !disabledGroups.contains(group)
    }

    /// Why `rule` is not applying, or nil when it is. One definition, so the
    /// agent's `effective` reason and any human surface can't disagree about
    /// which of the three switches is the one in the way.
    public func ineffectiveReason(for rule: TrafficRule) -> String? {
        if !enabled {
            return """
            The rules master switch is off, so no rule applies to traffic — including \
            this one. Turn it on with set_rules_enabled(enabled: true).
            """
        }
        if !isGroupEnabled(rule.group) {
            let group = rule.group ?? ""
            return """
            The group "\(group)" is switched off, so none of its rules apply. Turn it \
            back on with set_group_enabled(group: "\(group)", enabled: true).
            """
        }
        if !rule.isEnabled {
            return """
            This rule is disabled, so it will not apply to traffic. Enable it with \
            set_rule(id: …, enabled: true).
            """
        }
        return nil
    }
}

// MARK: - Engine surface

/// The outcome of a full-set sync via `setRules(_:)`: which rules were applied
/// and which were dropped, each with the reason. A caller syncing an
/// externally-owned rule set can then degrade gracefully — one malformed rule
/// no longer poisons the whole set — and surface exactly what was rejected.
public struct SetRulesReport: Equatable, Sendable {
    /// A single rule that failed validation and was left out of the applied set.
    public struct Rejection: Equatable, Sendable {
        public let id: UUID
        public let name: String
        public let reason: String

        public init(id: UUID, name: String, reason: String) {
            self.id = id
            self.name = name
            self.reason = reason
        }
    }

    /// Rules that passed validation and are now the active set, in order.
    public let applied: [TrafficRule]
    /// Rules dropped from the sync, each paired with its validation error.
    public let rejected: [Rejection]

    public init(applied: [TrafficRule], rejected: [Rejection]) {
        self.applied = applied
        self.rejected = rejected
    }

    /// True when every submitted rule was applied.
    public var allApplied: Bool { rejected.isEmpty }
}

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
    /// Replaces the whole rule list in one shot — for a caller (e.g. an embedding
    /// host) that owns the rule set elsewhere and syncs it wholesale rather than
    /// through per-rule CRUD. Applies every rule that validates and drops the
    /// rest, returning a `SetRulesReport` of what was applied and what was
    /// rejected (with reasons), so one malformed rule can't reject the whole set.
    @discardableResult
    func setRules(_ rules: [TrafficRule]) async -> SetRulesReport
    /// Switch a whole group on or off (`nil` = the ungrouped rules). Non-destructive:
    /// it sets the group's own switch (`RulesState.disabledGroups`) and leaves every
    /// member's `isEnabled` untouched, so switching a scenario off and back on
    /// restores exactly the rules that were on before.
    func setGroupEnabled(group: String?, enabled: Bool) async
}

// MARK: - Pattern matching

/// Memoized `NSRegularExpression` compilation. The rule matcher and substitutions
/// run on every request; compiling the same pattern each time is wasteful, so
/// cache by (pattern, case-sensitivity). Thread-safe: matching happens on NIO
/// event loops and async tasks alike.
public enum RegexCache {
    private struct Key: Hashable { let pattern: String; let caseInsensitive: Bool }
    /// The cache lives inside the `Mutex`, retiring the `nonisolated(unsafe)` that a
    /// bare `static var` + `NSLock` needed. Same reasoning as `HARExport.iso8601`.
    private static let cache = Mutex<[Key: NSRegularExpression]>([:])
    /// Far above any real rule set, but a bound nonetheless: patterns come from
    /// rules, and an agent cycling one-off regex rules programmatically would
    /// otherwise grow this for the process lifetime. Reset wholesale rather than
    /// tracking recency — recompiling the few dozen live patterns once after a
    /// reset is cheaper than LRU bookkeeping on every request.
    static let maxEntries = 512

    /// The compiled regex for `pattern`, or nil if it doesn't compile (invalid
    /// patterns are rejected at rule-creation time, so this is rare).
    public static func regex(_ pattern: String, caseInsensitive: Bool = true) -> NSRegularExpression? {
        let key = Key(pattern: pattern, caseInsensitive: caseInsensitive)
        return cache.withLock { cache in
            if let cached = cache[key] { return cached }
            let options: NSRegularExpression.Options = caseInsensitive ? [.caseInsensitive] : []
            guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return nil }
            if cache.count >= maxEntries { cache.removeAll(keepingCapacity: true) }
            cache[key] = regex
            return regex
        }
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
        return Glob.matches(pattern, string)
    }
}
