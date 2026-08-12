import Foundation
import Synchronization

/// The one glob matcher: case-insensitive, `*` standing for any run of characters.
///
/// It lived on `SSLScope` as `matches(pattern:host:)`, which is where it was first
/// needed — and then everything else came to borrow it. Three of its six callers are
/// not about the SSL scope and two are not about hosts: `TrafficRule` matches a whole
/// URL through it (`RuleMatch.matches`), a rule's `hostPattern` goes through it, the
/// flow filter's `host` goes through it, and `ClientCertificateConfig` picks an
/// identity with it. So the argument label was answering "host" for a URL, and rule
/// matching had to reach into the TLS-interception type to ask a question that has
/// nothing to do with TLS.
///
/// Same semantics, moved to a name that describes them. `SSLScope.matches` stays as a
/// deprecated forwarder because `LoomSharedModels` is a public SPM product and an
/// embedder may be calling it.
public enum Glob {
    /// Whether `string` matches `pattern`. `*.example.com` matches `api.example.com`
    /// but not the bare `example.com`; a bare `*` matches everything.
    ///
    /// Goes through the shared pattern cache, so the preparation (lowercasing the
    /// pattern, splitting it on `*`, encoding it to bytes) is paid once per distinct
    /// pattern rather than once per call — see `Glob.pattern(for:)`.
    public static func matches(_ pattern: String, _ string: String) -> Bool {
        Glob.pattern(for: pattern).matches(string)
    }

    /// The prepared form of `pattern`, from a bounded process-wide cache.
    ///
    /// The same shape as `RegexCache`, and for the same reason: the patterns come from
    /// rules / the SSL scope / client-certificate scopes, they are matched on the event
    /// loop for every request (rules and breakpoints both), and preparing one is
    /// strictly more expensive than looking it up. A caller that already holds a
    /// `Pattern` should keep holding it — this is for the call sites that only have the
    /// string.
    public static func pattern(for pattern: String) -> Pattern {
        cache.withLock { cache in
            if let prepared = cache[pattern] { return prepared }
            let prepared = Pattern(pattern)
            // Reset wholesale rather than tracking recency, exactly as `RegexCache`
            // does: re-preparing the few dozen live patterns once after a reset is
            // cheaper than LRU bookkeeping on every request.
            if cache.count >= maxCachedPatterns { cache.removeAll(keepingCapacity: true) }
            cache[pattern] = prepared
            return prepared
        }
    }

    private static let cache = Mutex<[String: Pattern]>([:])
    /// Far above any real rule set / scope list, but a bound nonetheless — an agent
    /// cycling one-off patterns programmatically would otherwise grow this for the
    /// process lifetime.
    static let maxCachedPatterns = 512

    /// A pattern with its per-call work done once: lowercased, split on `*`, encoded
    /// to bytes, and classified as a literal (no `*`) or a glob.
    ///
    /// Exists because the flow filter's host predicate ran per row over a 2 000-flow
    /// ring, and the un-prepared form lowercases the *pattern* again for every one of
    /// them — the same shape `FlowSearch.predicate()` documents on the window side,
    /// where hoisting the per-row work was the difference between 84 ms and 0.76 ms.
    ///
    /// ## Why the match runs over bytes
    ///
    /// The `String` implementation (`lowercased()` on both sides, then
    /// `String.range(of:)` per interior segment) is the whole cost of rule matching, and
    /// preparing the pattern only takes a third of it off. Measured over 1 000 requests
    /// against 50 glob rules: **107 ms unprepared, 74 ms prepared, 2.3 ms over bytes** —
    /// i.e. Foundation's Unicode-correct string search, not the preparation, was paying
    /// for 97 % of it. Rule and breakpoint matching both run on the event loop for every
    /// exchange, so that is 0.107 ms of event-loop time per request at 50 rules.
    ///
    /// Bytes are only correct where case folding is unambiguous, which is ASCII — the
    /// same boundary `ByteSearch` draws for body search, and for the same reason. So the
    /// byte path is taken **only when the pattern and the string are both pure ASCII**,
    /// and anything else falls back to the `String` implementation, which is unchanged.
    /// An IDN host spelled in native script, or a rule pattern with a non-ASCII path
    /// segment, therefore keeps Unicode-correct folding rather than silently changing
    /// which traffic a rule matches.
    public struct Pattern: Sendable, Equatable {
        /// Lowercased pattern, kept whole for the literal fast path.
        private let lowercased: String
        /// Nil when the pattern has no `*` — then a match is an equality check.
        private let segments: [String]?
        /// The same two, as case-folded ASCII bytes. Nil when the pattern is not pure
        /// ASCII, which is what disables the byte path for it.
        private let asciiLowercased: [UInt8]?
        private let asciiSegments: [[UInt8]]?

        public init(_ pattern: String) {
            let lowered = pattern.lowercased()
            lowercased = lowered
            let split = lowered.contains("*") ? lowered.components(separatedBy: "*") : nil
            segments = split
            if lowered.allSatisfy(\.isASCII) {
                asciiLowercased = Array(lowered.utf8)
                asciiSegments = split?.map { Array($0.utf8) }
            } else {
                asciiLowercased = nil
                asciiSegments = nil
            }
        }

        /// Whether this pattern has no `*`, so callers with a cheaper equality path of
        /// their own (comparing UTF-8 without materializing a `String`) can take it.
        public var isLiteral: Bool { segments == nil }

        /// The pattern, lowercased — for a caller taking the literal path itself.
        public var literal: String { lowercased }

        /// Whether this pattern can be matched over ASCII bytes — i.e. whether a caller
        /// that already holds the haystack's bytes may use `matches(asciiBytes:)`.
        public var supportsASCIIBytes: Bool { asciiLowercased != nil }

        /// Whether the host of `url` matches — the flow filter's question.
        ///
        /// A literal pattern never materializes the host: `URLHost.hostMatches` compares
        /// the URL's authority bytes in place, which is what keeps a host-filtered scan
        /// off the allocator. A glob has to see the host as a string, so it pays for one.
        public func matchesHost(ofURL url: String) -> Bool {
            guard !isLiteral else { return URLHost.hostMatches(urlString: url, lowercasedHost: lowercased) }
            guard let host = URLHost.host(ofURLString: url) else { return false }
            return matches(host)
        }

        public func matches(_ rawString: String) -> Bool {
            if asciiLowercased != nil {
                var string = rawString
                let byteVerdict: Bool? = string.withUTF8 { buffer in
                    guard Self.isASCII(buffer) else { return nil }
                    return matchesASCII(buffer)
                }
                if let byteVerdict { return byteVerdict }
            }
            return matchesUnicode(rawString)
        }

        /// Match against bytes the caller has already established are pure ASCII — the
        /// prepared form for a caller matching many patterns against one string (rule
        /// and breakpoint evaluation, where the URL is the same for every rule).
        ///
        /// Returns nil when this pattern can't take the byte path, so the caller can
        /// fall back to `matches(_:)` rather than silently getting a wrong answer.
        public func matches(asciiBytes: [UInt8]) -> Bool? {
            guard asciiLowercased != nil else { return nil }
            return asciiBytes.withUnsafeBufferPointer { matchesASCII($0) }
        }

        // MARK: - Byte path

        private func matchesASCII(_ haystack: UnsafeBufferPointer<UInt8>) -> Bool {
            guard let whole = asciiLowercased else { return matchesUnicode(String(decoding: haystack, as: UTF8.self)) }
            if Self.equalsFolded(haystack, whole) { return true }
            guard let segments = asciiSegments else { return false }

            var index = 0
            // A leading non-"*" segment must anchor at the start.
            if let first = segments.first, !first.isEmpty {
                guard haystack.count >= first.count, Self.matchesFolded(haystack, at: 0, first) else { return false }
                index = first.count
            }
            // Interior segments must appear in order, after the prefix.
            for segment in segments.dropFirst().dropLast() where !segment.isEmpty {
                guard let at = Self.find(segment, in: haystack, from: index) else { return false }
                index = at + segment.count
            }
            // A trailing non-"*" segment must anchor at the end *without overlapping*
            // what the prefix/interior already consumed — otherwise "ab*b" would match
            // the bare "ab" (prefix "ab" and suffix "b" reusing the same 'b').
            if segments.count > 1, let last = segments.last, !last.isEmpty {
                let start = haystack.count - last.count
                guard start >= index, Self.matchesFolded(haystack, at: start, last) else { return false }
            }
            return true
        }

        private static func isASCII(_ bytes: UnsafeBufferPointer<UInt8>) -> Bool {
            for byte in bytes where byte >= 0x80 { return false }
            return true
        }

        /// A–Z → a–z; every other byte untouched. Same fold as `ByteSearch`, and only
        /// ever applied to bytes already known to be ASCII.
        private static func fold(_ byte: UInt8) -> UInt8 {
            (byte >= 0x41 && byte <= 0x5A) ? byte + 0x20 : byte
        }

        private static func equalsFolded(_ haystack: UnsafeBufferPointer<UInt8>, _ folded: [UInt8]) -> Bool {
            guard haystack.count == folded.count else { return false }
            return matchesFolded(haystack, at: 0, folded)
        }

        private static func matchesFolded(
            _ haystack: UnsafeBufferPointer<UInt8>, at offset: Int, _ folded: [UInt8]
        ) -> Bool {
            var index = 0
            while index < folded.count {
                if fold(haystack[offset + index]) != folded[index] { return false }
                index += 1
            }
            return true
        }

        private static func find(
            _ folded: [UInt8], in haystack: UnsafeBufferPointer<UInt8>, from: Int
        ) -> Int? {
            guard haystack.count - from >= folded.count else { return nil }
            let first = folded[0]
            let last = haystack.count - folded.count
            var start = from
            while start <= last {
                if fold(haystack[start]) == first, matchesFolded(haystack, at: start, folded) { return start }
                start += 1
            }
            return nil
        }

        // MARK: - Unicode path

        /// The original `String` implementation, kept verbatim as the fallback for a
        /// pattern or a string that isn't pure ASCII.
        ///
        /// Internal rather than private so `GlobTests` can hold the byte path against
        /// it directly: "the two paths agree" is the whole safety argument for the byte
        /// path, and it cannot be checked through `matches(_:)`, which picks one.
        func matchesUnicode(_ rawString: String) -> Bool {
            let string = rawString.lowercased()
            if lowercased == string { return true }
            guard let segments else { return false }

            var index = string.startIndex

            // A leading non-"*" segment must anchor at the start.
            if let first = segments.first, !first.isEmpty {
                guard string.hasPrefix(first) else { return false }
                index = string.index(index, offsetBy: first.count)
            }
            // Interior segments must appear in order, after the prefix.
            for segment in segments.dropFirst().dropLast() where !segment.isEmpty {
                guard let range = string.range(of: segment, range: index ..< string.endIndex) else { return false }
                index = range.upperBound
            }
            // A trailing non-"*" segment must anchor at the end *without overlapping*
            // what the prefix/interior already consumed — otherwise "ab*b" would match
            // the bare "ab" (prefix "ab" and suffix "b" reusing the same 'b').
            if segments.count > 1, let last = segments.last, !last.isEmpty {
                guard string.hasSuffix(last),
                      string.distance(from: index, to: string.endIndex) >= last.count
                else { return false }
            }
            return true
        }
    }
}
