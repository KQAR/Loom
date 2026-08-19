import Foundation
import LoomSharedModels

/// In-pane find for the inspector's Body, Headers and Cookies tabs.
///
/// Distinct from the window's "Find in Requests" (⌘F), which filters the table.
struct InspectorFind: Equatable {
    var isPresented = false
    var needle = ""
    /// 0-based index among matches. Enter / next / prev steps it; the current
    /// hit is the darker wash and the one the pane scrolls to.
    var currentIndex = 0

    var trimmed: String {
        needle.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var isActive: Bool { isPresented && !trimmed.isEmpty }

    mutating func toggle() {
        isPresented.toggle()
        if !isPresented {
            needle = ""
            currentIndex = 0
        }
    }

    mutating func step(by delta: Int, matchCount: Int) {
        guard matchCount > 0 else { return }
        currentIndex = (currentIndex + delta % matchCount + matchCount) % matchCount
    }

    mutating func clamp(matchCount: Int) {
        if matchCount == 0 || currentIndex >= matchCount { currentIndex = 0 }
    }
}

/// Matching used by the in-pane find field. One function per haystack kind, so
/// the JSON tree and the raw text view cannot disagree on "does this contain that".
enum InspectorFindMatch {
    /// Cap on highlighted ranges in a body, so a one-character needle against a
    /// multi-megabyte payload cannot allocate millions of ranges on the main thread.
    static let maxRanges = 2_000

    /// Case-insensitive substring ranges, in document order. Empty needle → `[]`.
    static func ranges(of needle: String, in haystack: String) -> [Range<String.Index>] {
        let trimmed = needle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !haystack.isEmpty else { return [] }
        var result: [Range<String.Index>] = []
        var searchFrom = haystack.startIndex
        while result.count < maxRanges,
              let range = haystack.range(
                of: trimmed,
                options: .caseInsensitive,
                range: searchFrom ..< haystack.endIndex
              )
        {
            result.append(range)
            guard range.upperBound > searchFrom else { break }
            searchFrom = range.upperBound
        }
        return result
    }

    /// One walk: matching lines in document order, plus the ancestor paths
    /// that must be opened so a hit is reachable. A container that only matches
    /// because a child does is not itself a hit.
    static func jsonIndex(_ value: JSONValue, needle: String) -> JSONFindIndex {
        let trimmed = needle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return JSONFindIndex() }
        let matcher = NeedleMatcher(trimmed)
        var paths: [[Int]] = []
        var expand: Set<[Int]> = []
        func walk(_ v: JSONValue, key: String?, path: [Int]) -> Bool {
            let selfMatch = lineMatches(v, key: key, matcher: matcher)
            if selfMatch { paths.append(path) }
            var childHit = false
            switch v {
            case let .object(pairs):
                for (i, pair) in pairs.enumerated() {
                    if walk(pair.1, key: pair.0, path: path + [i]) { childHit = true }
                }
            case let .array(items):
                for (i, item) in items.enumerated() {
                    if walk(item, key: nil, path: path + [i]) { childHit = true }
                }
            default: break
            }
            let any = selfMatch || childHit
            if any {
                var prefix: [Int] = []
                expand.insert(prefix)
                for i in path {
                    prefix.append(i)
                    expand.insert(prefix)
                }
            }
            return any
        }
        _ = walk(value, key: nil, path: [])
        return JSONFindIndex(paths: paths, matched: Set(paths), expand: expand)
    }

    /// Count of matching JSON lines — the `N` in the pane's `1/N`.
    static func jsonMatchCount(_ value: JSONValue, needle: String) -> Int {
        jsonIndex(value, needle: needle).count
    }

    /// Paths of containers that must be opened to reveal a match.
    static func jsonExpansionPaths(_ value: JSONValue, needle: String) -> Set<[Int]> {
        jsonIndex(value, needle: needle).expand
    }

    /// Whether any field contains the needle. One hit per header / cookie row,
    /// so the pane's `1/N` and the row wash cannot drift.
    static func fieldsMatch(_ fields: [String], needle: String) -> Bool {
        let trimmed = needle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return rowMatches(fields, matcher: NeedleMatcher(trimmed))
    }

    /// Same as `fieldsMatch`, when the matcher is already built for a walk.
    static func rowMatches(_ fields: [String], matcher: NeedleMatcher) -> Bool {
        fields.contains { matcher.contains($0) }
    }

    /// Whether this node's own line (key and/or leaf) contains the needle —
    /// not whether a descendant does. Shared with `JSONNode` so the highlight
    /// and the count cannot drift.
    static func lineMatches(_ value: JSONValue, key: String?, matcher: NeedleMatcher) -> Bool {
        if let key, matcher.contains(key) { return true }
        switch value {
        case let .string(s): return matcher.contains(s)
        case let .number(n): return matcher.contains(n)
        case let .bool(b): return matcher.contains(b ? "true" : "false")
        case .null: return matcher.contains("null")
        case .object, .array: return false
        }
    }
}

/// Matching JSON lines in document order, and the containers that must open
/// to reach them. Search ORs `expand` with whatever was already open.
struct JSONFindIndex: Equatable, Sendable {
    var paths: [[Int]] = []
    /// The same lines as `paths`, as a set, for the per-node "is this line a
    /// hit" test. A node answering that by building a `NeedleMatcher` and
    /// re-matching itself cost one matcher allocation per visible node per
    /// render; a set membership is one hash of a short `[Int]`.
    var matched: Set<[Int]> = []
    var expand: Set<[Int]> = []
    var count: Int { paths.count }

    /// The matching line at `index`, or `nil` when the index is out of range.
    func path(at index: Int) -> [Int]? {
        paths.indices.contains(index) ? paths[index] : nil
    }
}
