import Foundation

/// Case-insensitive substring search prepared once and run over many haystacks.
///
/// ASCII needles — every one that has ever been typed at a URL — take a byte scan over
/// the haystack's UTF-8, folding case as it goes. Anything else falls back to
/// `range(of:options:.caseInsensitive)`, which is what correctness needs: case folding
/// outside ASCII is not a bit flip (`İ`, `ß`), and a hand-rolled fold would answer
/// differently from the engine's own matching.
///
/// **In `LoomSharedModels` rather than in the window**, because both surfaces search
/// the same text: the find bar's URL scope runs this over the rows on screen, and
/// `FlowQuery.urlContains` — the engine-side filter behind `get_recent_flows`,
/// `wait_for_flow` and `get_stats` — used `range(of:options:.caseInsensitive)` per row,
/// which bridges to `NSString` and walks grapheme clusters. Two substring matchers is
/// two answers to "does this URL contain that", and the slower one was the one an agent
/// hits.
public struct NeedleMatcher: Sendable {
    /// The lowercased needle bytes, or nil when the needle isn't ASCII.
    private let lowerASCII: [UInt8]?
    private let raw: String

    public init(_ needle: String) {
        raw = needle
        let bytes = Array(needle.utf8)
        lowerASCII = bytes.allSatisfy { $0 < 0x80 } ? bytes.map(Self.fold) : nil
    }

    @inline(__always) private static func fold(_ byte: UInt8) -> UInt8 {
        (byte >= 0x41 && byte <= 0x5A) ? byte &+ 0x20 : byte
    }

    public func contains(_ haystack: String) -> Bool {
        guard let lowerASCII else { return haystack.range(of: raw, options: .caseInsensitive) != nil }
        // Native Swift strings are contiguous UTF-8, so this is the path taken; a
        // bridged NSString isn't, and falls back rather than forcing a copy per row.
        let found = haystack.utf8.withContiguousStorageIfAvailable { hay in
            Self.contains(needle: lowerASCII, in: hay)
        }
        return found ?? (haystack.range(of: raw, options: .caseInsensitive) != nil)
    }

    private static func contains(needle: [UInt8], in hay: UnsafeBufferPointer<UInt8>) -> Bool {
        let n = needle.count
        guard n > 0 else { return true }
        guard hay.count >= n else { return false }
        let first = needle[0]
        let last = hay.count - n
        var i = 0
        outer: while i <= last {
            if fold(hay[i]) == first {
                var j = 1
                while j < n {
                    if fold(hay[i &+ j]) != needle[j] {
                        i &+= 1
                        continue outer
                    }
                    j &+= 1
                }
                return true
            }
            i &+= 1
        }
        return false
    }
}
