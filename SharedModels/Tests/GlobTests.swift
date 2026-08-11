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

    /// The deprecated forwarder stays behaviour-identical while it exists: it is a
    /// public API of an SPM product an embedder may still be calling.
    @Test func theDeprecatedForwarderStillAgrees() {
        #expect(SSLScope.matches(pattern: "*.example.com", host: "api.example.com"))
        #expect(!SSLScope.matches(pattern: "*.example.com", host: "example.com"))
    }
}
