import Foundation
import SharedModels

/// A thread-safe holder for the traffic-rules state, shared between the actor
/// (which mutates it) and the forwarding path (which reads a snapshot per
/// request). Kept off the actor so forwarding never has to `await` for rules.
///
/// Persisted as a single JSON file under Application Support (same directory as
/// the CA store) rather than UserDefaults: mock/rewrite bodies can be large, and
/// UserDefaults is eagerly loaded by `cfprefsd` and meant for small values, not
/// multi-KB blobs. The whole set is loaded into memory once at launch (matching
/// always runs over the in-memory snapshot), so a plain file is the right fit.
final class RulesConfig: @unchecked Sendable {
    private let lock = NSLock()
    private var state: RulesState
    private let fileURL: URL?

    /// - Parameter fileURL: persistence backing; `nil` disables it (tests). When
    ///   it points at the default location and no file exists yet, a one-time
    ///   migration imports rules previously saved in UserDefaults.
    init(state: RulesState = RulesState(), fileURL: URL? = RulesConfig.defaultFileURL) {
        self.fileURL = fileURL
        if let fileURL, let saved = Self.load(from: fileURL) {
            self.state = saved
        } else if let fileURL, fileURL == Self.defaultFileURL, let migrated = Self.migrateFromUserDefaults() {
            self.state = migrated
            Self.persist(migrated, to: fileURL)
        } else {
            self.state = state
        }
    }

    /// `~/Library/Application Support/com.loom/rules.json` — mirrors `FileCAStore`'s
    /// directory. `nil` only if the Application Support URL can't be resolved.
    static var defaultFileURL: URL? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        else { return nil }
        return base
            .appendingPathComponent("com.loom", isDirectory: true)
            .appendingPathComponent("rules.json")
    }

    func snapshot() -> RulesState {
        lock.lock()
        defer { lock.unlock() }
        return state
    }

    func setEnabled(_ enabled: Bool) {
        mutate { $0.enabled = enabled }
    }

    func add(_ rule: TrafficRule) {
        mutate { $0.rules.append(rule) }
    }

    /// Replaces the rule with the same id. Returns false when no such rule exists.
    func update(_ rule: TrafficRule) -> Bool {
        var found = false
        mutate { state in
            if let index = state.rules.firstIndex(where: { $0.id == rule.id }) {
                state.rules[index] = rule
                found = true
            }
        }
        return found
    }

    /// Enable/disable every rule in a group (`nil` = the ungrouped rules).
    func setGroupEnabled(group: String?, enabled: Bool) {
        mutate { state in
            for index in state.rules.indices where state.rules[index].group == group {
                state.rules[index].isEnabled = enabled
            }
        }
    }

    /// Removes the rule with the given id. Returns false when no such rule exists.
    func delete(id: UUID) -> Bool {
        var found = false
        mutate { state in
            let before = state.rules.count
            state.rules.removeAll { $0.id == id }
            found = state.rules.count != before
        }
        return found
    }

    private func mutate(_ body: (inout RulesState) -> Void) {
        lock.lock()
        body(&state)
        let updated = state
        lock.unlock()
        if let fileURL { Self.persist(updated, to: fileURL) }
    }

    // MARK: - Persistence

    /// Pretty-printed so the file stays human-inspectable / hand-editable; written
    /// atomically with 0600 perms under a 0700 dir, like the CA store.
    private static func persist(_ state: RulesState, to url: URL) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(state) else { return }
        let dir = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        guard (try? data.write(to: url, options: .atomic)) != nil else { return }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private static func load(from url: URL) -> RulesState? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(RulesState.self, from: data)
    }

    /// One-time import of rules saved by an earlier build under UserDefaults key
    /// `com.loom.rules`; clears the key afterwards so it isn't re-read. Returns nil
    /// when there was nothing to migrate.
    private static func migrateFromUserDefaults() -> RulesState? {
        let key = "com.loom.rules"
        let defaults = UserDefaults.standard
        guard let data = defaults.data(forKey: key),
              let state = try? JSONDecoder().decode(RulesState.self, from: data)
        else { return nil }
        defaults.removeObject(forKey: key)
        return state
    }
}
