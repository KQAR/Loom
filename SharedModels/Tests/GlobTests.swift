import Foundation
import Testing

@testable import LoomSharedModels

/// The one glob matcher, with the semantics five subsystems depend on: the SSL scope,
/// a rule's URL pattern, a rule's host pattern, the flow filter's `host`, and mutual-TLS
/// identity selection.
///
/// These assertions used to sit in `CertificateAuthorityTests` under a
/// `SSLScopeTests` suite, because that is where the function lived. They are here with
/// the matcher now — a glob has nothing to do with TLS, which is the whole reason it
/// moved.
@Suite struct GlobTests {
    @Test func wildcardMatching() {
        #expect(Glob.matches("*", "anything.com"))
        #expect(Glob.matches("example.com", "example.com"))
        #expect(Glob.matches("EXAMPLE.com", "example.COM"))
        #expect(Glob.matches("*.example.com", "api.example.com"))
        #expect(!Glob.matches("*.example.com", "example.com"))
        #expect(Glob.matches("api.*", "api.test"))
        #expect(Glob.matches("*.foo.*", "a.foo.bar"))
        #expect(!Glob.matches("api.example.com", "other.com"))
    }

    @Test func wildcardMatching_prefixAndSuffixDoNotOverlap() {
        // Regression: prefix "ab" + suffix "b" reused the same 'b', so a bare "ab"
        // wrongly matched "ab*b".
        #expect(!Glob.matches("ab*b", "ab"))
        #expect(Glob.matches("ab*b", "abb"))
        #expect(Glob.matches("ab*b", "abXb"))
        // The empty-wildcard cases stay correct.
        #expect(Glob.matches("a*c", "ac"))
        #expect(!Glob.matches("a*c", "ab"))
    }

    /// A URL, not a host — `RuleMatch` globs the whole thing, and the matcher's old
    /// name (`SSLScope.matches(pattern:host:)`) said otherwise at three call sites.
    @Test func matchesAWholeURLAsReadily() {
        #expect(Glob.matches("https://api.example.com/v1/*", "https://api.example.com/v1/orders?page=2"))
        #expect(!Glob.matches("https://api.example.com/v1/*", "https://api.example.com/v2/orders"))
    }

    /// The prepared form answers identically — it is the same code with the per-call
    /// work hoisted, so anything that diverges here is a filter silently disagreeing
    /// with the rule engine.
    @Test func thePreparedFormAgreesWithTheOneShotForm() {
        let cases = ["*", "example.com", "*.example.com", "api.*", "*.foo.*", "ab*b", "a*c", ""]
        let strings = ["example.com", "api.example.com", "a.foo.bar", "ab", "abb", "abXb", "ac", "API.EXAMPLE.com", ""]
        for pattern in cases {
            let prepared = Glob.Pattern(pattern)
            for string in strings {
                #expect(
                    prepared.matches(string) == Glob.matches(pattern, string),
                    "\"\(pattern)\" vs \"\(string)\": prepared and one-shot disagree"
                )
            }
        }
    }

    @Test func aPatternWithNoWildcardReportsItselfLiteral() {
        // What lets a caller take an equality path that never materializes a `String`
        // (see `URLHost.hostMatches`).
        #expect(Glob.Pattern("api.example.com").isLiteral)
        #expect(Glob.Pattern("API.example.com").literal == "api.example.com")
        #expect(!Glob.Pattern("*.example.com").isLiteral)
    }

    /// The byte path and the `String` path must answer identically wherever the byte
    /// path is taken at all — it is a faster spelling of the same semantics, and the
    /// only thing standing between "46× cheaper rule matching" and "rules quietly stop
    /// matching traffic they used to".
    @Test func theBytePathAgreesWithTheStringPath() {
        let patterns = [
            "*", "", "example.com", "EXAMPLE.com", "*.example.com", "api.*", "*.foo.*",
            "ab*b", "a*c", "a**c", "*a*", "https://api.example.com/v1/*",
            "*/resource/*/items", "*.example.com/*?page=2",
        ]
        let strings = [
            "", "a", "ab", "abb", "abXb", "ac", "example.com", "API.EXAMPLE.com",
            "api.example.com", "a.foo.bar", "https://api.example.com/v1/orders?page=2",
            "https://api.example.com/v2/orders", "https://h/resource/12/items",
        ]
        for pattern in patterns {
            let prepared = Glob.Pattern(pattern)
            #expect(prepared.supportsASCIIBytes, "\"\(pattern)\" is ASCII and should take the byte path")
            for string in strings {
                #expect(
                    prepared.matches(string) == prepared.matchesUnicode(string),
                    "\"\(pattern)\" vs \"\(string)\": the byte path and the string path disagree"
                )
                #expect(
                    prepared.matches(asciiBytes: Array(string.utf8)) == prepared.matchesUnicode(string),
                    "\"\(pattern)\" vs \"\(string)\": the prepared-bytes entry point disagrees"
                )
            }
        }
    }

    /// Non-ASCII on either side keeps Unicode-correct case folding, because ASCII is
    /// the only range where folding a byte at a time is unambiguous — the same
    /// boundary `ByteSearch` draws for body search.
    @Test func nonASCIIStaysOnTheStringPath() {
        let unicodePattern = Glob.Pattern("*.münchen.example")
        #expect(!unicodePattern.supportsASCIIBytes)
        #expect(unicodePattern.matches("api.MÜNCHEN.example"))
        #expect(unicodePattern.matches("api.münchen.example"))
        #expect(!unicodePattern.matches("api.munchen.example"))

        // An ASCII pattern against a non-ASCII string: the pattern can take the byte
        // path in principle, the string can't, so the answer comes from the string path.
        let asciiPattern = Glob.Pattern("*.example")
        #expect(asciiPattern.supportsASCIIBytes)
        #expect(asciiPattern.matches("MÜNCHEN.example"))
        #expect(!asciiPattern.matches("münchen.other"))
        // Punycode — what actually reaches the wire — is ASCII and matches either way.
        #expect(asciiPattern.matches("xn--mnchen-3ya.example"))
    }

    /// The cache hands back a prepared pattern, not a fresh one, and a cached pattern
    /// answers exactly like a freshly built one.
    @Test func theCacheReturnsAnEquivalentPattern() {
        let pattern = "*.cached.example.com"
        let first = Glob.pattern(for: pattern)
        let second = Glob.pattern(for: pattern)
        #expect(first == second)
        #expect(first == Glob.Pattern(pattern))
        #expect(Glob.matches(pattern, "api.CACHED.example.com"))
    }

    /// The deprecated forwarder stays behaviour-identical while it exists: it is a
    /// public API of an SPM product an embedder may still be calling.
    @Test func theDeprecatedForwarderStillAgrees() {
        #expect(SSLScope.matches(pattern: "*.example.com", host: "api.example.com"))
        #expect(!SSLScope.matches(pattern: "*.example.com", host: "example.com"))
    }
}
