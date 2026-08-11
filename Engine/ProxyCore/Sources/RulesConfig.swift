import Foundation
import LoomSharedModels
import Synchronization

/// A thread-safe holder for the traffic-rules state, shared between the actor
/// (which mutates it) and the forwarding path (which reads a snapshot per
/// request). Kept off the actor so forwarding never has to `await` for rules.
///
/// Persisted as a single JSON file under Application Support (same directory as
/// the CA store) rather than UserDefaults: mock/rewrite bodies can be large, and
/// UserDefaults is eagerly loaded by `cfprefsd` and meant for small values, not
/// multi-KB blobs. The whole set is loaded into memory once at launch (matching
/// always runs over the in-memory snapshot), so a plain file is the right fit.
/// The rule state lives inside the `Mutex`, so this is plainly `Sendable`.
final class RulesConfig: Sendable {
    private let state: Mutex<RulesState>
    private let fileURL: URL?
    /// Writes are serialized here, and **enqueued while the lock is held**, so the
    /// file can only ever move forward through the same sequence of states the
    /// in-memory value did. Persisting after unlocking (as this used to) left two
    /// concurrent mutations free to land on disk in the opposite order, so the file
    /// silently regressed to a stale snapshot and the next launch reloaded it.
    ///
    /// The write itself stays off the lock: `snapshot()` runs on the event loop for
    /// every request, and a rule edit must never make it wait on a disk write.
    /// Same shape as `FlowPersistence`/`AuditPersistence`, `flush()` included.
    private let persistQueue = DispatchQueue(label: "com.loom.rulesconfig.persist")

    /// - Parameter fileURL: persistence backing; `nil` disables it (tests). When
    ///   it points at the default location and no file exists yet, a one-time
    ///   migration imports rules previously saved in UserDefaults.
    init(state: RulesState = RulesState(), fileURL: URL? = RulesConfig.defaultFileURL) {
        self.fileURL = fileURL
        if let fileURL, let saved = Self.load(from: fileURL) {
            self.state = Mutex(saved)
        } else if let fileURL, fileURL == Self.defaultFileURL, let migrated = Self.migrateFromUserDefaults() {
            self.state = Mutex(migrated)
            Self.persist(migrated, to: fileURL)
        } else {
            self.state = Mutex(state)
        }
    }

    /// `~/Library/Application Support/com.loom/rules.json` — mirrors `FileCAStore`'s
    /// directory.
    static var defaultFileURL: URL? {
        LoomPaths.appSupportFile("rules.json")
    }

    func snapshot() -> RulesState {
        state.withLock { $0 }
    }

    func setEnabled(_ enabled: Bool) {
        mutate { $0.enabled = enabled }
    }

    func add(_ rule: TrafficRule) {
        mutate { $0.rules.append(rule) }
    }

    /// Atomically replace the entire rule list — the external-sync path used by
    /// an embedding host that owns the rule set elsewhere.
    func replaceAll(_ rules: [TrafficRule]) {
        mutate { $0.rules = rules }
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
            if enabled { state.disabledGroups.remove(group) }
            else { state.disabledGroups.insert(group) }
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
        state.withLock { state in
            body(&state)
            // A group switch outlives its members otherwise, and a *new* rule
            // written into that group name later would be silently off. Pruning
            // here — one place every mutation passes through — means the set only
            // ever holds groups that exist.
            if !state.disabledGroups.isEmpty {
                state.disabledGroups.formIntersection(Set(state.rules.map(\.group)))
            }
            let updated = state
            // Enqueued under the lock: that is what pins the write order to the
            // mutation order. Only the enqueue is on the lock; the encode + write run
            // on the queue.
            if let fileURL { persistQueue.async { Self.persist(updated, to: fileURL) } }
        }
    }

    /// Block until every queued write has run — call from the quit handler, and
    /// from any test that reads the file straight after mutating.
    func flush() {
        persistQueue.sync {}
    }

    // MARK: - Persistence

    /// Pretty-printed so the file stays human-inspectable / hand-editable; written
    /// atomically with 0600 perms under a 0700 dir, like the CA store.
    private static func persist(_ state: RulesState, to url: URL) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        do {
            let data = try encoder.encode(state)
            try LoomPaths.createSecureDirectory(at: url.deletingLastPathComponent())
            try data.write(to: url, options: .atomic)
            LoomPaths.restrictToOwner(url)
        } catch {
            // Rules are primary user data; a lost write means edits vanish on
            // relaunch. Can't throw from here (mutation setters are sync), so log.
            Log.store.error("Rules persist failed; changes may not survive relaunch: \(String(describing: error))")
        }
    }

    private static func load(from url: URL) -> RulesState? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil } // first run
        do {
            return try JSONDecoder().decode(RulesState.self, from: Data(contentsOf: url))
        } catch {
            // Every rule silently disappears: traffic an agent believes is mocked or
            // re-mapped would quietly hit the real upstream instead.
            Log.store.error("""
            Rules file at \(url.path, privacy: .public) could not be read; \
            starting with no rules — traffic you expect to be mocked/mapped will hit \
            the real upstream: \(String(describing: error))
            """)
            return nil
        }
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
