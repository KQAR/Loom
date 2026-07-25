import Foundation

/// Extracts the host from an absolute URL string.
///
/// `Flow.host` is read far more often than it looks: the sidebar's host grouping,
/// the host filter on the flow table (once per flow per render), `FlowQuery`
/// matching, and the SQLite `host` column on every save. It used to build a
/// `URLComponents` each time — full CFURL parsing to pull out one substring, which
/// dominated those paths at capture scale.
///
/// This scans the authority directly for the shapes real traffic produces
/// (`https://host[:port]/…`, with or without userinfo, IPv4/IPv6 literals) and
/// **falls back to `URLComponents` for anything else**, so the answer is identical
/// to before — including the parts a hand-rolled parser has no business
/// reimplementing: percent-decoding (`exa%6dple.com` → `example.com`), IDN/punycode
/// decoding (`xn--fsq.com` → `例.com`), and rejecting a malformed URL outright
/// (a backslash in the authority yields nil).
public enum URLHost {
    /// The host component, matching `URLComponents(string:)?.host` exactly.
    /// Nil when the string isn't a URL with an authority; `""` for an empty
    /// authority (`https://`), which is what `URLComponents` also reports.
    public static func host(ofURLString string: String) -> String? {
        switch hostRange(in: string) {
        case let .range(bounds):
            return String(decoding: string.utf8[bounds], as: UTF8.self)
        case .needsFoundation:
            return fallback(string)
        }
    }

    /// Whether the URL's host equals `host`, without materializing it.
    ///
    /// Equivalent to `host(ofURLString:) == host`, but a filter over a long list
    /// compares far more often than it needs new `String`s — this keeps a
    /// host-filtered table off the allocator entirely on the fast path.
    public static func hostMatches(urlString: String, host: String) -> Bool {
        switch hostRange(in: urlString) {
        case let .range(bounds):
            return urlString.utf8[bounds].elementsEqual(host.utf8)
        case .needsFoundation:
            return fallback(urlString) == host
        }
    }

    // MARK: - The shared scan

    private enum ScanResult {
        /// Byte range of the host inside the original string.
        case range(Range<String.UTF8View.Index>)
        /// A shape whose semantics belong to Foundation (escapes, punycode,
        /// malformed authority, or simply not an absolute URL).
        case needsFoundation
    }

    private static func hostRange(in string: String) -> ScanResult {
        let bytes = string.utf8

        // MARK: scheme "://"
        var cursor = bytes.startIndex
        var schemeLength = 0
        while cursor < bytes.endIndex, bytes[cursor] != .colon {
            guard isSchemeByte(bytes[cursor], isFirst: schemeLength == 0) else { return .needsFoundation }
            schemeLength += 1
            cursor = bytes.index(after: cursor)
        }
        // No colon, an empty scheme, or something that isn't a scheme: not our shape.
        guard cursor < bytes.endIndex, schemeLength > 0 else { return .needsFoundation }
        var authorityStart = bytes.index(after: cursor) // past ':'
        for _ in 0 ..< 2 { // require "//"
            guard authorityStart < bytes.endIndex, bytes[authorityStart] == .slash else {
                return .needsFoundation
            }
            authorityStart = bytes.index(after: authorityStart)
        }

        // MARK: authority runs to the first '/', '?' or '#'
        var authorityEnd = bytes.endIndex
        var lastAt: String.UTF8View.Index?
        cursor = authorityStart
        while cursor < bytes.endIndex {
            let byte = bytes[cursor]
            if byte == .slash || byte == .question || byte == .hash {
                authorityEnd = cursor
                break
            }
            // Anything outside the plain set (percent-escape, non-ASCII, backslash…)
            // has semantics worth deferring to Foundation for.
            guard isPlainAuthorityByte(byte) else { return .needsFoundation }
            // `a@b@c.com` resolves to `c.com`: the *last* '@' ends the userinfo.
            if byte == .at { lastAt = cursor }
            cursor = bytes.index(after: cursor)
        }

        // MARK: host = authority minus userinfo, minus ":port"
        let hostStart = lastAt.map { bytes.index(after: $0) } ?? authorityStart
        var hostEnd = authorityEnd
        if hostStart < authorityEnd, bytes[hostStart] == .openBracket {
            // IPv6 literal: the colons inside the brackets are not a port separator,
            // and `URLComponents` keeps the brackets in `host`.
            var scan = hostStart
            while scan < authorityEnd, bytes[scan] != .closeBracket {
                scan = bytes.index(after: scan)
            }
            guard scan < authorityEnd else { return .needsFoundation } // unterminated
            hostEnd = bytes.index(after: scan) // include ']'
            // Only a port may follow the literal.
            if hostEnd < authorityEnd, bytes[hostEnd] != .colon { return .needsFoundation }
        } else {
            var scan = hostStart
            while scan < authorityEnd {
                if bytes[scan] == .colon {
                    hostEnd = scan
                    break
                }
                scan = bytes.index(after: scan)
            }
        }

        let bounds = hostStart ..< hostEnd
        // Punycode is Foundation's job — it decodes `xn--` labels to Unicode. Checked
        // over the bytes so the common case still doesn't allocate.
        guard !containsPunycodeLabel(bytes[bounds]) else { return .needsFoundation }
        return .range(bounds)
    }

    /// The original implementation, for every shape the fast path declines.
    private static func fallback(_ string: String) -> String? {
        URLComponents(string: string)?.host
    }

    private static let punycodePrefix: [UInt8] = [
        UInt8(ascii: "x"), UInt8(ascii: "n"), .hyphen, .hyphen,
    ]

    /// Whether any *label* starts with `xn--` (case-insensitive), i.e. whether
    /// Foundation would punycode-decode this host. Checked only at label starts —
    /// where an A-label can legally appear — so an ordinary host costs one
    /// comparison per label rather than a substring search.
    private static func containsPunycodeLabel(_ host: String.UTF8View.SubSequence) -> Bool {
        var index = host.startIndex
        var atLabelStart = true
        while index < host.endIndex {
            if atLabelStart, hasPunycodePrefix(host, at: index) { return true }
            atLabelStart = host[index] == .dot
            index = host.index(after: index)
        }
        return false
    }

    private static func hasPunycodePrefix(_ host: String.UTF8View.SubSequence, at start: String.UTF8View.Index) -> Bool {
        var index = start
        for expected in punycodePrefix {
            guard index < host.endIndex, host[index] | 0x20 == expected else { return false }
            index = host.index(after: index)
        }
        return true
    }

    /// RFC 3986 scheme: ALPHA *( ALPHA / DIGIT / "+" / "-" / "." )
    private static func isSchemeByte(_ byte: UInt8, isFirst: Bool) -> Bool {
        if isAlpha(byte) { return true }
        if isFirst { return false }
        return isDigit(byte) || byte == .plus || byte == .hyphen || byte == .dot
    }

    /// The authority bytes this parser is willing to interpret itself: unreserved
    /// characters plus the authority delimiters. Deliberately tight — `%`,
    /// non-ASCII and anything else routes to `URLComponents`.
    private static func isPlainAuthorityByte(_ byte: UInt8) -> Bool {
        isAlpha(byte) || isDigit(byte)
            || byte == .hyphen || byte == .dot || byte == .underscore || byte == .tilde
            || byte == .colon || byte == .at || byte == .openBracket || byte == .closeBracket
    }

    private static func isAlpha(_ byte: UInt8) -> Bool {
        (byte | 0x20) >= UInt8(ascii: "a") && (byte | 0x20) <= UInt8(ascii: "z")
    }

    private static func isDigit(_ byte: UInt8) -> Bool {
        byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9")
    }
}

private extension UInt8 {
    static let colon = UInt8(ascii: ":")
    static let slash = UInt8(ascii: "/")
    static let question = UInt8(ascii: "?")
    static let hash = UInt8(ascii: "#")
    static let at = UInt8(ascii: "@")
    static let openBracket = UInt8(ascii: "[")
    static let closeBracket = UInt8(ascii: "]")
    static let hyphen = UInt8(ascii: "-")
    static let dot = UInt8(ascii: ".")
    static let underscore = UInt8(ascii: "_")
    static let tilde = UInt8(ascii: "~")
    static let plus = UInt8(ascii: "+")
}
