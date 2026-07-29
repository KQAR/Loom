import Testing
import Foundation
@testable import LoomProxyCore
import LoomSharedModels

/// `RulesConfig` and `InterceptionConfig` serialize their in-memory state under a
/// lock, but they used to write to disk *after* unlocking — on the caller's thread,
/// with no ordering between callers. Two overlapping MCP write tools (each tool call
/// is its own Task) could therefore take snapshots in order A→B and have A's write
/// land last, leaving the file holding A while memory held B. Nothing logged; the
/// divergence only surfaced on the next launch, as a deleted rule reappearing or a
/// stale SSL scope quietly turning interception off.
///
/// These tests hammer concurrent mutations and assert the persisted state matches
/// the final in-memory state.
@Suite("Config persist ordering", .timeLimit(.minutes(1)))
struct ConfigPersistOrderingTests {
    private func makeRule(_ name: String) -> TrafficRule {
        TrafficRule(name: name, match: RuleMatch(urlPattern: "*"), actions: RuleActions(route: .block))
    }

    @Test func concurrentRuleMutations_leaveTheFileMatchingMemory() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("loom-rules-order-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("rules.json")

        let config = RulesConfig(fileURL: url)

        // Add from many tasks at once, then delete half the same way — the shape of
        // an agent editing rules in a burst.
        let rules = (0 ..< 40).map { makeRule("rule-\($0)") }
        await withTaskGroup(of: Void.self) { group in
            for rule in rules {
                group.addTask { config.add(rule) }
            }
        }
        await withTaskGroup(of: Void.self) { group in
            for rule in rules.prefix(20) {
                group.addTask { _ = config.delete(id: rule.id) }
            }
        }
        config.flush()

        let inMemory = Set(config.snapshot().rules.map(\.name))
        let onDisk = Set(RulesConfig(fileURL: url).snapshot().rules.map(\.name))
        #expect(inMemory.count == 20, "20 of 40 rules should survive")
        #expect(onDisk == inMemory, "the file must match memory, not a stale snapshot")
    }

    /// The SSL scope is the higher-stakes one: a stale scope surviving a relaunch
    /// means HTTPS stops being intercepted and the user just sees an empty capture.
    @Test func concurrentScopeUpdates_persistTheFinalValue() async throws {
        let suite = "com.loom.tests.persistorder.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let config = InterceptionConfig(defaults: defaults)
        await withTaskGroup(of: Void.self) { group in
            for index in 0 ..< 40 {
                group.addTask { config.update(SSLScope(enabled: true, include: ["host-\(index).test"])) }
            }
        }
        // One last update, uncontended, fixes what the final state must be.
        config.update(SSLScope(enabled: true, include: ["final.test"]))
        config.flush()

        let reloaded = InterceptionConfig(defaults: defaults).snapshot()
        #expect(reloaded.include == ["final.test"], "the stored scope must be the last one written, not an earlier one")
        #expect(reloaded == config.snapshot(), "stored scope and in-memory scope must agree")
    }
}
