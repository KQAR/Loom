import Foundation

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
    /// Substring of a request *or* response header, ASCII-case-insensitive.
    ///
    /// Without a colon the needle matches a header's name or its value (`authorization`
    /// finds the header; `Bearer ey` finds the token that carries it). With a colon it
    /// splits into `name: value` and both halves must hit on the *same* header — so
    /// `x-env: staging` can't be satisfied by an `x-env` header plus an unrelated
    /// `staging` elsewhere in the exchange.
    public var headerContains: String?
    /// Substring of the captured request *or* response body, ASCII-case-insensitive
    /// and matched over the raw bytes (so a non-UTF-8 payload is searched too, and a
    /// non-ASCII needle works byte-for-byte).
    ///
    /// Matched against what Loom *captured*: a body over the capture cap is recorded
    /// as a prefix, and such a flow reports `isBodyTruncated`, so a miss on one of
    /// those isn't proof the bytes weren't on the wire.
    public var bodyContains: String?

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
        bodyContains: String? = nil
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
        self.bodyContains = bodyContains
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
    public func matchesMetadata(_ flow: Flow) -> Bool {
        if let since, flow.startedAt < since { return false }
        if let methods, !methods.isEmpty {
            let method = flow.request.method
            guard methods.contains(where: { $0.caseInsensitiveCompare(method) == .orderedSame }) else { return false }
        }
        if let host {
            guard let flowHost = flow.host, SSLScope.matches(pattern: host, host: flowHost) else { return false }
        }
        if let urlContains, !urlContains.isEmpty {
            guard flow.request.url.range(of: urlContains, options: .caseInsensitive) != nil else { return false }
        }
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
        if let headerContains, !headerContains.isEmpty {
            guard Self.headerMatches(needle: headerContains, in: flow) else { return false }
        }
        return true
    }

    /// The predicates that need a hydrated flow. Trivially true when none is set,
    /// so a caller can apply it unconditionally.
    public func matchesBodies(_ flow: Flow) -> Bool {
        guard let bodyContains, !bodyContains.isEmpty else { return true }
        let needle = Array(bodyContains.utf8)
        return ByteSearch.contains(needle, in: flow.request.body)
            || ByteSearch.contains(needle, in: flow.response?.body)
    }

    // MARK: - Header matching

    private static func headerMatches(needle: String, in flow: Flow) -> Bool {
        // Split once per flow rather than per header. Substrings, so no copies.
        let namePart: Substring?
        let valuePart: Substring
        if let colon = needle.firstIndex(of: ":") {
            namePart = needle[needle.startIndex ..< colon].trimmed
            valuePart = needle[needle.index(after: colon)...].trimmed
        } else {
            namePart = nil
            valuePart = needle[...]
        }
        let name = namePart.map { Array($0.utf8) }
        let value = Array(valuePart.utf8)

        func hits(_ headers: [HeaderPair]) -> Bool {
            headers.contains { header in
                if let name {
                    // `name: value` form — both halves must hit the same header.
                    // An empty value half degrades to "does this header exist".
                    return ByteSearch.contains(name, in: header.name)
                        && (value.isEmpty || ByteSearch.contains(value, in: header.value))
                }
                return ByteSearch.contains(value, in: header.name)
                    || ByteSearch.contains(value, in: header.value)
            }
        }
        return hits(flow.request.headers) || hits(flow.response?.headers ?? [])
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
    public static func contains(_ needle: [UInt8], in haystack: Data?) -> Bool {
        guard let haystack, !needle.isEmpty, haystack.count >= needle.count else { return false }
        return haystack.withUnsafeBytes { raw in
            search(needle, in: raw.bindMemory(to: UInt8.self))
        }
    }

    /// String overload — searches the UTF-8 view in place rather than materializing
    /// `Data`, so scanning every header of every flow in the ring allocates nothing.
    public static func contains(_ needle: [UInt8], in haystack: String) -> Bool {
        guard !needle.isEmpty else { return false }
        var haystack = haystack
        return haystack.withUTF8 { search(needle, in: $0) }
    }

    private static func search(_ needle: [UInt8], in bytes: UnsafeBufferPointer<UInt8>) -> Bool {
        guard bytes.count >= needle.count else { return false }
        let folded = needle.map(fold)
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
