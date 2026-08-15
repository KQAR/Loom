import Foundation
import Testing
@testable import LoomSharedModels

/// `RuleMatch` holds its glob prepared, instead of looking it up in the
/// process-wide cache per rule per request. That is a cache living inside a value,
/// so the only way it can be wrong is by going stale — these pin every way its two
/// inputs (`urlPattern`, `style`) can change.
///
/// The reason it is worth the risk is in `TrafficRule.matches`: 0.0246 ms/request
/// against 0.0110 over 200 all-glob rules, on the event loop, per exchange.
@Suite struct RulePreparedPatternTests {
    @Test func aPatternEditedInPlaceMatchesTheNewPattern() {
        var match = RuleMatch(urlPattern: "https://*.old.test/*", style: .glob)
        #expect(match.matches(method: "GET", url: "https://api.old.test/x"))

        match.urlPattern = "https://*.new.test/*"
        #expect(match.matches(method: "GET", url: "https://api.new.test/x"))
        #expect(!match.matches(method: "GET", url: "https://api.old.test/x"),
                "the prepared glob must follow the pattern, or an edited rule keeps matching what it used to")
    }

    @Test func aStyleSwitchedToGlobPreparesOne() {
        var match = RuleMatch(urlPattern: "https://*.example.test/*", style: .exact)
        #expect(!match.matches(method: "GET", url: "https://api.example.test/x"), "exact: the URL is not the pattern")

        match.style = .glob
        #expect(match.matches(method: "GET", url: "https://api.example.test/x"))

        match.style = .exact
        #expect(!match.matches(method: "GET", url: "https://api.example.test/x"),
                "and switching away from glob must stop globbing")
    }

    @Test func aDecodedRuleIsPreparedToo() throws {
        let match = try JSONDecoder().decode(
            RuleMatch.self,
            from: Data(#"{"urlPattern":"https://*.decoded.test/*","style":"glob"}"#.utf8)
        )
        #expect(match.matches(method: "GET", url: "https://api.decoded.test/x"))
        #expect(!match.matches(method: "GET", url: "https://api.other.test/x"))
    }

    /// A cache must not reach the file format. `RuleMatch`'s `encode(to:)` names its
    /// keys, so this cannot happen by synthesis — but nothing else checks the bytes,
    /// and `rules.json` is also read by builds that predate the field.
    @Test func thePreparedPatternIsNotEncoded() throws {
        let match = RuleMatch(urlPattern: "https://*.example.test/*", style: .glob, methods: ["GET"])
        let json = try #require(
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(match)) as? [String: Any]
        )
        #expect(json["preparedGlob"] == nil)
        #expect(Set(json.keys) == ["urlPattern", "style", "methods"], "the wire shape is unchanged")
    }

    /// The prepared pattern is a pure function of the two inputs, which is what keeps
    /// synthesized `Equatable` correct — two matches that agree on the inputs must
    /// compare equal however each was built.
    @Test func equalityIgnoresHowTheMatchWasBuilt() throws {
        var edited = RuleMatch(urlPattern: "https://*.a.test/*", style: .glob)
        edited.urlPattern = "https://*.b.test/*"
        let built = RuleMatch(urlPattern: "https://*.b.test/*", style: .glob)
        let decoded = try JSONDecoder().decode(RuleMatch.self, from: JSONEncoder().encode(built))
        #expect(edited == built)
        #expect(decoded == built)
    }
}
