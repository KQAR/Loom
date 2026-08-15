import Foundation
import Testing
@testable import LoomSharedModels

/// What `rules.json` may and may not carry.
@Suite struct RulesStatePersistenceTests {
    /// Session drop counts belong to the store, not to the persisted configuration.
    /// The decode side always ignored the key; the encode side used to write it.
    @Test func droppedCountsAreNotPersisted() throws {
        var state = RulesState(
            enabled: true,
            rules: [TrafficRule(name: "r", match: RuleMatch(urlPattern: "*"), actions: RuleActions(route: .block))]
        )
        state.droppedCounts = [UUID(): 7]
        let json = try #require(
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(state)) as? [String: Any]
        )
        #expect(json["droppedCounts"] == nil, "a session count in rules.json comes back attached to traffic that never arrived")
        #expect(json["rules"] != nil)
        #expect(json["enabled"] as? Bool == true)

        // A file written by an older build still loads, with the stale counts dropped.
        let legacy = #"{"enabled":true,"rules":[],"droppedCounts":{"x":3}}"#
        let decoded = try JSONDecoder().decode(RulesState.self, from: Data(legacy.utf8))
        #expect(decoded.droppedCounts.isEmpty)
    }
}
