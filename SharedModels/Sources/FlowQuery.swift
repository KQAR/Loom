import Foundation

/// Which half of an exchange a content predicate searches.
///
/// `any` is the default and the old behaviour. The other two exist because the
/// question usually has a side: "which request carried this id" is about request
/// bodies, "who set this cookie" is about response headers. Searching both and
/// letting the caller sort it out is not free — a list endpoint's response tends
/// to contain every id in the system, so the noise scales with the data.
public enum ExchangeSide: String, Equatable, Codable, Sendable, CaseIterable {
    case any
    case request
    case response

    var includesRequest: Bool { self != .response }
    var includesResponse: Bool { self != .request }
}

/// A filter over captured flows — the "find the exchange I care about" predicate
/// shared by the MCP read tools and any embedder.
///
/// Why it exists: an agent asking "what did the app POST to /orders that failed?"
/// could previously only pull the newest N summaries and scan them in its own
/// context. That is expensive (tokens) and *wrong* (a match older than N is
/// invisible, so "no such request" is indistinguishable from "beyond the limit").
/// Filtering belongs next to the store, where it can run over the whole ring and
/// only then apply the limit.
///
/// All set fields AND together; an unset field matches everything. `isEmpty`
/// means "match all", which lets the store take its cheap newest-N path.
///
/// ## Cheap vs. body predicates
/// Everything except `bodyContains` matches on metadata the store keeps in memory
/// for every flow, so it costs a scan and nothing else. `bodyContains` needs the
/// payload, which lives out-of-line (see `FlowStore.hydrated`) — `needsBodies`
/// tells the store to hydrate a candidate, and it only ever does so for a flow
/// that already passed every cheap predicate. Split via `matchesMetadata` /
/// `matchesBodies` so that ordering is the store's to enforce rather than a
/// convention it has to remember.
public struct FlowQuery: Equatable, Sendable {
    /// Host to match, exactly or as a glob (`*.example.com`) — same semantics as
    /// the SSL-scope host patterns, so one notion of "host pattern" exists.
    public var host: String?
    /// HTTP methods to include, compared case-insensitively.
    public var methods: [String]?
    /// Case-insensitive substring of the absolute URL.
    public var urlContains: String?
    /// Inclusive status-code bounds. An exact status sets both.
    public var statusMin: Int?
    public var statusMax: Int?
    /// Only exchanges that failed: a transport error, or status ≥ 400.
    public var onlyErrors: Bool
    /// Only flows started at or after this instant.
    public var since: Date?
    /// Originating device, by remote IP (see `SourceDevice.groupingKey`).
    public var deviceIP: String?
    /// Originating local app, by bundle id or display name (`SourceApp.groupingKey`).
    public var sourceApp: String?
    /// Substring of a header, ASCII-case-insensitive. `headerSide` picks which
    /// side is searched; the default is both.
    ///
    /// Without a colon the needle matches a header's name or its value (`authorization`
    /// finds the header; `Bearer ey` finds the token that carries it). With a colon it
    /// splits into `name: value` and both halves must hit on the *same* header — so
    /// `x-env: staging` can't be satisfied by an `x-env` header plus an unrelated
    /// `staging` elsewhere in the exchange.
    public var headerContains: String?
    /// Which side `headerContains` searches. "Who sent this auth header" is a
    /// question about requests, and answering it over both sides buries the answer.
    public var headerSide: ExchangeSide = .any
    /// Substring of a captured body, ASCII-case-insensitive and matched over the raw
    /// bytes (so a non-UTF-8 payload is searched too, and a non-ASCII needle works
    /// byte-for-byte). `bodySide` picks which side is searched; the default is both.
    ///
    /// Matched against what Loom *captured*: a body over the capture cap is recorded
    /// as a prefix, and such a flow reports `isBodyTruncated`, so a miss on one of
    /// those isn't proof the bytes weren't on the wire.
    public var bodyContains: String?
    /// Which side `bodyContains` searches.
    ///
    /// The reason this exists: "which request carried this order id" is the most
    /// common content search there is, and it is a question about *request* bodies —
    /// but a list endpoint's response usually contains every id in the system, so
    /// searching both sides answers it with a page of noise around the one hit. The
    /// caller could not narrow it, only guess (by method, say), which is a heuristic
    /// dressed as an answer.
    public var bodySide: ExchangeSide = .any

    public init(
        host: String? = nil,
        methods: [String]? = nil,
        urlContains: String? = nil,
        statusMin: Int? = nil,
        statusMax: Int? = nil,
        onlyErrors: Bool = false,
        since: Date? = nil,
        deviceIP: String? = nil,
        sourceApp: String? = nil,
        headerContains: String? = nil,
        headerSide: ExchangeSide = .any,
        bodyContains: String? = nil,
        bodySide: ExchangeSide = .any
    ) {
        self.host = host
        self.methods = methods
        self.urlContains = urlContains
        self.statusMin = statusMin
        self.statusMax = statusMax
        self.onlyErrors = onlyErrors
        self.since = since
        self.deviceIP = deviceIP
        self.sourceApp = sourceApp
        self.headerContains = headerContains
        self.headerSide = headerSide
        self.bodyContains = bodyContains
        self.bodySide = bodySide
    }

    /// The match-everything query.
    public static let all = FlowQuery()

    /// True when nothing is constrained — callers can skip filtering entirely.
    public var isEmpty: Bool { self == .all }

    /// True when a predicate needs the payload, so the caller must hand
    /// `matchesBodies` a hydrated flow for the verdict to mean anything.
    public var needsBodies: Bool { !(bodyContains ?? "").isEmpty }

    /// The full predicate. Only correct for a flow that carries its bodies when
    /// `needsBodies` — a store scanning body-free rows uses the split pair instead.
    public func matches(_ flow: Flow) -> Bool {
        matchesMetadata(flow) && matchesBodies(flow)
    }

    /// Every predicate that reads only in-memory metadata.
    ///
    /// **A scan must not call this per row** — it prepares the query's own side of the
    /// work every time (see `MetadataPredicate`). Kept for the one-off caller and for
    /// the public API an embedder may hold.
    public func matchesMetadata(_ flow: Flow) -> Bool {
        metadataPredicate().matches(flow)
    }

    /// The predicates that need a hydrated flow. Trivially true when none is set,
    /// so a caller can apply it unconditionally.
    public func matchesBodies(_ flow: Flow) -> Bool {
        bodyPredicate().matches(flow)
    }

    // MARK: - Prepared predicates

    /// The metadata predicate with everything that doesn't depend on the flow hoisted
    /// out of the loop.
    ///
    /// Measured over a full 2 000-flow ring, per scan, before and after:
    ///
    /// | filter | per-row | hoisted |
    /// |---|---|---|
    /// | `host` exact | 3.92 ms | 0.31 ms |
    /// | `host` glob | 4.75 ms | 1.72 ms |
    /// | `url_contains` | 8.28 ms | 0.65 ms |
    /// | `header_contains` | 7.15 ms | 2.02 ms |
    ///
    /// Four costs were being paid per row rather than per query: the host pattern was
    /// lowercased again for every flow (and the flow's own host materialized as a
    /// `String` even when the pattern is a literal), `url_contains` went through
    /// `range(of:options:.caseInsensitive)` — an `NSString` bridge and a grapheme walk —
    /// the `header_contains` needle was re-split and re-encoded to bytes, and
    /// `ByteSearch` re-folded the needle's case inside every call.
    ///
    /// This is the same shape `FlowSearch.predicate()` documents on the window side,
    /// where hoisting the per-row work was the difference between 84 ms and 0.76 ms per
    /// keystroke. The engine side is the one an *agent* pays for: `get_recent_flows`,
    /// `wait_for_flow` and `get_stats` all scan through here, and `wait_for_flow` scans
    /// on every emission of the flow stream.
    public func metadataPredicate() -> MetadataPredicate {
        MetadataPredicate(self)
    }

    public func bodyPredicate() -> BodyPredicate {
        BodyPredicate(self)
    }

    /// A query's metadata predicate, prepared once.
    public struct MetadataPredicate: Sendable {
        private let since: Date?
        private let methods: [String]?
        /// Nil when unfiltered. A literal pattern (no `*`) is compared against the URL's
        /// authority in place — `URLHost.hostMatches` never materializes the host.
        private let host: Glob.Pattern?
        private let url: NeedleMatcher?
        private let onlyErrors: Bool
        private let statusMin: Int?
        private let statusMax: Int?
        private let deviceIP: String?
        private let sourceApp: String?
        private let header: HeaderNeedle?

        init(_ query: FlowQuery) {
            since = query.since
            methods = (query.methods?.isEmpty ?? true) ? nil : query.methods
            host = query.host.map(Glob.Pattern.init)
            url = (query.urlContains?.isEmpty ?? true) ? nil : query.urlContains.map(NeedleMatcher.init)
            onlyErrors = query.onlyErrors
            statusMin = query.statusMin
            statusMax = query.statusMax
            deviceIP = query.deviceIP
            sourceApp = query.sourceApp
            header = (query.headerContains?.isEmpty ?? true)
                ? nil
                : query.headerContains.map { HeaderNeedle($0, side: query.headerSide) }
        }

        public func matches(_ flow: Flow) -> Bool {
            if let since, flow.startedAt < since { return false }
            if let methods {
                let method = flow.request.method
                guard methods.contains(where: { $0.caseInsensitiveCompare(method) == .orderedSame }) else { return false }
            }
            if let host, !host.matchesHost(ofURL: flow.request.url) { return false }
            if let url, !url.contains(flow.request.url) { return false }
            if onlyErrors {
                // A pending flow is neither an error nor known-good: exclude it, so
                // "show me the failures" never returns something still in flight.
                guard flow.error != nil || (flow.statusCode ?? 0) >= 400 else { return false }
            }
            if let statusMin {
                guard let status = flow.statusCode, status >= statusMin else { return false }
            }
            if let statusMax {
                guard let status = flow.statusCode, status <= statusMax else { return false }
            }
            if let deviceIP {
                guard flow.sourceDevice?.groupingKey == deviceIP else { return false }
            }
            if let sourceApp {
                guard let app = flow.sourceApp,
                      app.groupingKey.caseInsensitiveCompare(sourceApp) == .orderedSame
                      || app.name.caseInsensitiveCompare(sourceApp) == .orderedSame
                else { return false }
            }
            if let header, !header.matches(flow) { return false }
            return true
        }
    }

    /// A query's body predicate, prepared once. The needle's case is folded here rather
    /// than inside every `ByteSearch` call.
    public struct BodyPredicate: Sendable {
        private let folded: [UInt8]?
        private let side: ExchangeSide

        init(_ query: FlowQuery) {
            let needle = query.bodyContains ?? ""
            folded = needle.isEmpty ? nil : ByteSearch.folded(Array(needle.utf8))
            side = query.bodySide
        }

        public func matches(_ flow: Flow) -> Bool {
            guard let folded else { return true }
            let inRequest = side.includesRequest && ByteSearch.contains(folded: folded, in: flow.request.body)
            let inResponse = side.includesResponse && ByteSearch.contains(folded: folded, in: flow.response?.body)
            return inRequest || inResponse
        }
    }

    /// A `header_contains` needle, split into its `name: value` halves and encoded to
    /// case-folded bytes once. It used to be re-split and re-encoded per flow, with a
    /// comment saying "split once per flow rather than per header" — one level short.
    struct HeaderNeedle: Sendable {
        /// Nil for the plain form, which matches a name *or* a value.
        private let name: [UInt8]?
        private let value: [UInt8]
        private let side: ExchangeSide

        init(_ needle: String, side: ExchangeSide) {
            let namePart: Substring?
            let valuePart: Substring
            if let colon = needle.firstIndex(of: ":") {
                namePart = needle[needle.startIndex ..< colon].trimmed
                valuePart = needle[needle.index(after: colon)...].trimmed
            } else {
                namePart = nil
                valuePart = needle[...]
            }
            name = namePart.map { ByteSearch.folded(Array($0.utf8)) }
            value = ByteSearch.folded(Array(valuePart.utf8))
            self.side = side
        }

        func matches(_ flow: Flow) -> Bool {
            let inRequest = side.includesRequest && hits(flow.request.headers)
            let inResponse = side.includesResponse && hits(flow.response?.headers ?? [])
            return inRequest || inResponse
        }

        private func hits(_ headers: [HeaderPair]) -> Bool {
            headers.contains { header in
                if let name {
                    // `name: value` form — both halves must hit the same header.
                    // An empty value half degrades to "does this header exist".
                    return ByteSearch.contains(folded: name, in: header.name)
                        && (value.isEmpty || ByteSearch.contains(folded: value, in: header.value))
                }
                return ByteSearch.contains(folded: value, in: header.name)
                    || ByteSearch.contains(folded: value, in: header.value)
            }
        }
    }

}

private extension Substring {
    var trimmed: Substring {
        var slice = self
        while let first = slice.first, first == " " || first == "\t" { slice = slice.dropFirst() }
        while let last = slice.last, last == " " || last == "\t" { slice = slice.dropLast() }
        return slice
    }
}

/// ASCII-case-insensitive substring search over raw bytes.
///
/// Why bytes and not `String.range(of:options: .caseInsensitive)`: a captured body
/// can be 5 MB and need not be valid UTF-8 (protobuf, images, a compressed frame).
/// Decoding one to `String` just to search it copies the whole payload and gives up
/// entirely on the non-text case. Folding ASCII in place searches both kinds without
/// allocating, and a non-ASCII needle (say Chinese text in a JSON body) still matches
/// byte-for-byte because UTF-8 is preserved — only A–Z/a–z fold, which is exactly the
/// range where case-insensitivity is unambiguous.
public enum ByteSearch {
    /// The needle with ASCII case folded, so a scan does it once instead of inside
    /// every call. `search` used to fold per invocation — an allocation per row, per
    /// header.
    public static func folded(_ needle: [UInt8]) -> [UInt8] { needle.map(fold) }

    public static func contains(_ needle: [UInt8], in haystack: Data?) -> Bool {
        contains(folded: folded(needle), in: haystack)
    }

    /// String overload — searches the UTF-8 view in place rather than materializing
    /// `Data`, so scanning every header of every flow in the ring allocates nothing.
    public static func contains(_ needle: [UInt8], in haystack: String) -> Bool {
        contains(folded: folded(needle), in: haystack)
    }

    /// Same, for a needle already folded by `folded(_:)`.
    public static func contains(folded needle: [UInt8], in haystack: Data?) -> Bool {
        guard let haystack, !needle.isEmpty, haystack.count >= needle.count else { return false }
        return haystack.withUnsafeBytes { raw in
            search(needle, in: raw.bindMemory(to: UInt8.self))
        }
    }

    public static func contains(folded needle: [UInt8], in haystack: String) -> Bool {
        guard !needle.isEmpty else { return false }
        var haystack = haystack
        return haystack.withUTF8 { search(needle, in: $0) }
    }

    /// `needle` must already be folded (`folded(_:)`).
    private static func search(_ folded: [UInt8], in bytes: UnsafeBufferPointer<UInt8>) -> Bool {
        guard bytes.count >= folded.count, !folded.isEmpty else { return false }
        let first = folded[0]
        let last = bytes.count - folded.count
        var start = 0
        while start <= last {
            if fold(bytes[start]) == first {
                var offset = 1
                while offset < folded.count, fold(bytes[start + offset]) == folded[offset] { offset += 1 }
                if offset == folded.count { return true }
            }
            start += 1
        }
        return false
    }

    /// A–Z → a–z; every other byte (including UTF-8 continuation bytes) untouched.
    private static func fold(_ byte: UInt8) -> UInt8 {
        (byte >= 0x41 && byte <= 0x5A) ? byte + 0x20 : byte
    }
}
