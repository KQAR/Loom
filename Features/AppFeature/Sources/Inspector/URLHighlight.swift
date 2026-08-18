import Foundation

/// Which parts of a request URL carry a colour in the inspector header.
///
/// A URL is one unbroken monospaced line, and the thing being looked for in it
/// is almost always one of four facts: the scheme, the host, the path, or the
/// query. Highlighting is the cheapest way to make that a glance — the same
/// editor exception DESIGN.md already grants the Raw head and the JSON body.
///
/// Two rules keep it from becoming decoration:
///
/// - **The same tokens as everywhere else.** Scheme is `Syntax.name` (a keyword),
///   host is `accent` (ink vanished into the header in Dark), path is
///   `Syntax.string`, query is `Syntax.number`. A header inventing its own hues
///   would be the inspector-parity bug those tokens exist to prevent.
/// - **Leave alone rather than guess.** Punctuation (`://`, `#fragment`, userinfo)
///   stays unspanned, and a string that is not `scheme://…` gets no spans at all —
///   a debugger must show what was sent, not a reconstructed URL.
///
/// Pure and index-based so the view can paint an `AttributedString` without
/// re-deriving what a host is. Ranges are over the original string: the header
/// copies what was captured, never a percent-decoded rebuild.
enum URLHighlight {
    enum Role: Equatable {
        /// `https` — the scheme token, not the following `://`.
        case scheme
        /// Host plus a non-default port when the URL spelled one. Userinfo is not
        /// this: credentials are not the origin someone is scanning for.
        case host
        /// From the first `/` after the authority, up to but not including `?`/`#`.
        case path
        /// From `?` up to but not including `#`. The `?` is included so the query
        /// reads as one unit.
        case query
    }

    struct Span: Equatable {
        let range: Range<String.Index>
        let role: Role
    }

    static func spans(in url: String) -> [Span] {
        guard let (scheme, authorityStart) = schemeAndAuthorityStart(in: url) else { return [] }
        var spans: [Span] = [Span(range: scheme, role: .scheme)]

        let authorityEnd = url[authorityStart...].firstIndex(where: isAuthorityEnd) ?? url.endIndex
        let hostStart: String.Index = {
            guard let at = url[authorityStart..<authorityEnd].lastIndex(of: "@") else {
                return authorityStart
            }
            return url.index(after: at)
        }()
        if hostStart < authorityEnd {
            spans.append(Span(range: hostStart..<authorityEnd, role: .host))
        }

        guard authorityEnd < url.endIndex else { return spans }

        var cursor = authorityEnd
        if url[cursor] == "/" {
            let pathEnd = url[cursor...].firstIndex(where: { $0 == "?" || $0 == "#" }) ?? url.endIndex
            if cursor < pathEnd {
                spans.append(Span(range: cursor..<pathEnd, role: .path))
            }
            cursor = pathEnd
            guard cursor < url.endIndex else { return spans }
        }
        if url[cursor] == "?" {
            let queryEnd = url[cursor...].firstIndex(of: "#") ?? url.endIndex
            spans.append(Span(range: cursor..<queryEnd, role: .query))
        }
        return spans
    }

    /// RFC 3986 scheme (`ALPHA *( ALPHA / DIGIT / "+" / "-" / "." )`) followed by
    /// `://`. Anything else is not an absolute URL Loom captured.
    private static func schemeAndAuthorityStart(
        in url: String
    ) -> (scheme: Range<String.Index>, authorityStart: String.Index)? {
        var cursor = url.startIndex
        guard cursor < url.endIndex, isSchemeFirst(url[cursor]) else { return nil }
        cursor = url.index(after: cursor)
        while cursor < url.endIndex, url[cursor] != ":" {
            guard isSchemeRest(url[cursor]) else { return nil }
            cursor = url.index(after: cursor)
        }
        guard cursor < url.endIndex, cursor > url.startIndex else { return nil }
        let scheme = url.startIndex..<cursor
        var rest = url.index(after: cursor)
        for _ in 0..<2 {
            guard rest < url.endIndex, url[rest] == "/" else { return nil }
            rest = url.index(after: rest)
        }
        return (scheme, rest)
    }

    private static func isAuthorityEnd(_ character: Character) -> Bool {
        character == "/" || character == "?" || character == "#"
    }

    private static func isSchemeFirst(_ character: Character) -> Bool {
        character.isASCII && character.isLetter
    }

    private static func isSchemeRest(_ character: Character) -> Bool {
        guard character.isASCII else { return false }
        return character.isLetter || character.isNumber
            || character == "+" || character == "-" || character == "."
    }
}
