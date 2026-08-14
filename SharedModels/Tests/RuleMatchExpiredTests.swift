import Foundation
import Testing
@testable import LoomSharedModels

/// `hostPattern` folded into `urlPattern`. A leftover on disk expires the match
/// rather than keeping a second host glob in force — `urlPattern: "*"` plus a
/// host glob used to mean "this host"; matching the leftover would silently
/// change what the rule does.
@Suite struct RuleMatchExpiredTests {
    @Test func leftoverHostPattern_expiresTheMatch() throws {
        let match = try JSONDecoder().decode(
            RuleMatch.self,
            from: Data(#"{"urlPattern":"*","hostPattern":"*.example.com"}"#.utf8)
        )
        #expect(match.isExpired)
        #expect(match.expiredHostPattern == "*.example.com")
        #expect(!match.matches(method: "GET", url: "https://api.example.com/x"))
    }

    @Test func encodeWritesExpiredHostPattern_neverHostPattern() throws {
        let match = RuleMatch(urlPattern: "*", expiredHostPattern: "*.example.com")
        let json = try #require(
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(match)) as? [String: Any]
        )
        #expect(json["expiredHostPattern"] as? String == "*.example.com")
        #expect(json["hostPattern"] == nil)
    }

    @Test func alreadyExpiredJSON_roundTripsWithoutRevivingHostPattern() throws {
        let match = try JSONDecoder().decode(
            RuleMatch.self,
            from: Data(#"{"urlPattern":"*","style":"glob","expiredHostPattern":"*.x.test"}"#.utf8)
        )
        #expect(match.expiredHostPattern == "*.x.test")
        let json = try #require(
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(match)) as? [String: Any]
        )
        #expect(json["hostPattern"] == nil)
        #expect(json["expiredHostPattern"] as? String == "*.x.test")
    }

    @Test func activeRules_excludeExpired() {
        let live = TrafficRule(
            name: "live", match: RuleMatch(urlPattern: "*"), actions: RuleActions(route: .block)
        )
        let dead = TrafficRule(
            name: "dead",
            match: RuleMatch(urlPattern: "*", expiredHostPattern: "*.x"),
            actions: RuleActions(route: .block)
        )
        let state = RulesState(rules: [live, dead])
        #expect(state.activeRules.map(\.name) == ["live"])
        #expect(state.ineffectiveReason(for: dead)?.contains("expired") == true)
        #expect(state.ineffectiveReason(for: live) == nil)
    }

    @Test func urlGlob_coversWhatHostPatternUsedTo() {
        let match = RuleMatch(urlPattern: "https://*.example.test*")
        #expect(match.matches(method: "GET", url: "https://api.example.test/x"))
        #expect(!match.matches(method: "GET", url: "https://api.other.test/x"))
    }
}
