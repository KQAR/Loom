import Foundation

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
    /// Lowercases both sides on every call. A caller matching one pattern against many
    /// strings — a filter over a flow list, a rule over a burst of requests — should
    /// prepare it once with `Glob.Pattern` instead.
    public static func matches(_ pattern: String, _ string: String) -> Bool {
        Pattern(pattern).matches(string)
    }

    /// A pattern with its per-call work done once: lowercased, split on `*`, and
    /// classified as a literal (no `*`) or a glob.
    ///
    /// Exists because the flow filter's host predicate ran per row over a 2 000-flow
    /// ring, and the un-prepared form lowercases the *pattern* again for every one of
    /// them — the same shape `FlowSearch.predicate()` documents on the window side,
    /// where hoisting the per-row work was the difference between 84 ms and 0.76 ms.
    public struct Pattern: Sendable, Equatable {
        /// Lowercased pattern, kept whole for the literal fast path.
        private let lowercased: String
        /// Nil when the pattern has no `*` — then a match is an equality check.
        private let segments: [String]?

        public init(_ pattern: String) {
            let lowered = pattern.lowercased()
            lowercased = lowered
            segments = lowered.contains("*") ? lowered.components(separatedBy: "*") : nil
        }

        /// Whether this pattern has no `*`, so callers with a cheaper equality path of
        /// their own (comparing UTF-8 without materializing a `String`) can take it.
        public var isLiteral: Bool { segments == nil }

        /// The pattern, lowercased — for a caller taking the literal path itself.
        public var literal: String { lowercased }

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
