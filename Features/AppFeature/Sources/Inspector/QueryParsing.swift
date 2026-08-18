import Foundation

/// One `name=value` pair from a URL's query string.
///
/// Not `URLQueryPair`, which the rule editor already owns for a query *predicate*,
/// and not Foundation's `URLQueryItem`, which cannot express the two
/// distinctions below.
///
/// A list, not a dictionary, for the reason `HeaderPair` is one: order and
/// repeats are on the wire and are meaningful. `?id=1&id=2` is how array
/// parameters are spelled by half the web, and folding it to one entry would
/// hide the exact thing someone opens this tab to check.
struct URLQueryPair: Equatable, Identifiable {
    /// Positional — two pairs can be identical, so nothing else is unique.
    let index: Int
    let name: String
    let value: String
    /// Whether the pair had no `=` at all (`?debug`), as opposed to an explicitly
    /// empty value (`?debug=`). Servers routinely treat those differently, so the
    /// view must be able to.
    let isFlag: Bool

    var id: Int { index }
}

/// Splitting a URL's query into pairs.
///
/// Hand-rolled rather than `URLComponents.queryItems`, which loses the two
/// distinctions above: it reports `?debug` and `?debug=` identically (a nil
/// value in both cases, on some OS versions), and it silently returns nil for a
/// URL it considers malformed — which a debugging proxy sees constantly and must
/// still display.
enum QueryParsing {
    static func items(inURL url: String) -> [URLQueryPair] {
        guard let start = url.firstIndex(of: "?") else { return [] }
        var query = url[url.index(after: start)...]
        // A fragment is not part of the query; it is also not sent to the server,
        // which is worth not showing next to things that were.
        if let hash = query.firstIndex(of: "#") { query = query[..<hash] }
        guard !query.isEmpty else { return [] }

        return query.split(separator: "&", omittingEmptySubsequences: true)
            .enumerated()
            .map { index, pair in
                guard let equals = pair.firstIndex(of: "=") else {
                    return URLQueryPair(index: index, name: decode(pair), value: "", isFlag: true)
                }
                return URLQueryPair(
                    index: index,
                    name: decode(pair[..<equals]),
                    value: decode(pair[pair.index(after: equals)...]),
                    isFlag: false
                )
            }
    }

    /// Percent-decoding only, and **`+` is left alone**. See `PercentDecoding`.
    private static func decode(_ component: some StringProtocol) -> String {
        let raw = String(component)
        return PercentDecoding.decoded(raw) ?? raw
    }
}
