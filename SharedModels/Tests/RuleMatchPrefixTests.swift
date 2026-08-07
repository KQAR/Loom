import Foundation
import Testing
@testable import LoomSharedModels

/// The default `urlPattern` style is a case-insensitive prefix, and it runs once per
/// rule per exchange on the event loop. It used to be
/// `url.lowercased().hasPrefix(pattern.lowercased())` — two whole-string allocations
/// per rule, per request, to answer a question that usually fails on the first byte.
///
/// The replacement folds ASCII case as it walks and allocates nothing. That is a
/// deliberate narrowing: Unicode case folding no longer applies. URLs reaching this
/// point are ASCII (a non-ASCII host is punycode, a non-ASCII path is
/// percent-encoded), and a pattern that genuinely needs Unicode matching has the
/// exact and glob styles. These pin both halves so the narrowing stays a decision.
@Suite struct RuleMatchPrefixTests {
    private func matches(_ url: String, _ pattern: String) -> Bool {
        RuleMatch(urlPattern: pattern).matches(method: "GET", url: url)
    }

    @Test func prefix_matchesRegardlessOfCase() {
        #expect(matches("https://API.Example.test/v1/thing", "https://api.example.test/v1"))
        #expect(matches("https://api.example.test/v1/thing", "HTTPS://API.EXAMPLE.TEST"))
        #expect(matches("https://api.example.test/v1", "https://api.example.test/v1"))
    }

    @Test func prefix_rejectsANonPrefix() {
        #expect(!matches("https://api.example.test/v1", "https://api.example.test/v2"))
        // Longer pattern than URL: no prefix, and no read past the end.
        #expect(!matches("https://a.test", "https://a.test/longer"))
        #expect(!matches("", "https://a.test"))
    }

    @Test func anEmptyPatternMatchesAnything() {
        // Unchanged from `hasPrefix("")`, and the schema documents `url_pattern` as
        // required — this only pins that an empty one doesn't crash or invert.
        #expect(matches("https://a.test", ""))
    }

    /// The digit/symbol range around `A-Z` is where a careless ASCII fold goes wrong:
    /// `_` (0x5F) and `?` (0x3F) differ by exactly the 0x20 bit, as do `[` and `{`.
    @Test func theCaseFoldDoesNotReachBeyondLetters() {
        #expect(!matches("https://a.test/_x", "https://a.test/?x"))
        #expect(!matches("https://a.test/[x", "https://a.test/{x"))
        #expect(matches("https://a.test/_x", "https://a.test/_x"))
    }

    @Test func nonASCIIMatchesByteForByteRatherThanByCaseFolding() {
        #expect(matches("https://a.test/café", "https://a.test/café"))
        // No Unicode folding: É does not match é here. The exact/glob styles are for
        // patterns that need more than ASCII.
        #expect(!matches("https://a.test/CAFÉ", "https://a.test/café"))
    }

    /// A `*` anywhere switches to the glob style, and finding it must not go through
    /// Foundation's `range(of:)` — it is asked once per rule per exchange.
    @Test func aStarStillSelectsTheGlobStyle() {
        #expect(matches("https://api.example.test/v1/thing", "https://*.example.test/*"))
        #expect(!matches("https://api.other.test/v1", "https://*.example.test/*"))
    }
}
