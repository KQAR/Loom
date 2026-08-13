import Foundation
import LoomSharedModels
import Synchronization

/// A thread-safe holder for the SSL-proxying scope, shared between the actor
/// (which updates it) and the NIO handlers (which read a snapshot synchronously
/// on each CONNECT). Kept off the actor so the event loop never has to `await`.
///
/// The scope is persisted (UserDefaults) so HTTPS interception survives an app
/// relaunch — otherwise every launch resets to disabled, every HTTPS connection
/// falls back to a blind tunnel, and nothing gets captured.
/// The scope lives inside the `Mutex`, so the type is plainly `Sendable`: the
/// "every touch goes through the lock" convention is now the compiler's to enforce
/// rather than a comment's to assert.
final class InterceptionConfig: Sendable {
    private let scope: Mutex<SSLScope>
    /// `UserDefaults` has no `Sendable` conformance, though it is documented as
    /// thread-safe. This is the one unverified thing left in the type, and it is
    /// narrowed to the property rather than blanketing the class with
    /// `@unchecked Sendable` — the mutable state next to it is now checked.
    nonisolated(unsafe) private let defaults: UserDefaults?
    private let storageKey = "com.loom.sslScope"
    /// Writes serialized here and enqueued under the lock, so the stored scope can
    /// only move forward through the states the in-memory one did. Persisting after
    /// unlocking let two concurrent updates land in the opposite order — and a
    /// stale scope surviving a relaunch means HTTPS silently stops being
    /// intercepted, which reads as "Loom captured nothing" with no error anywhere.
    private let persistQueue = DispatchQueue(label: "com.loom.interceptionconfig.persist")

    /// - Parameter defaults: persistence backing; `nil` disables it (tests). When
    ///   non-nil and a scope was previously saved, that saved scope wins over the
    ///   `scope` argument.
    init(scope: SSLScope = .disabled, defaults: UserDefaults? = .standard) {
        self.defaults = defaults
        if let defaults, var saved = Self.load(from: defaults, key: storageKey) {
            // Before the lock exists, and before the listeners are up: an install
            // carrying the old seeded wildcard must not decrypt even one connection
            // under it. Doing this from the app's first refresh instead would leave a
            // window in which whatever the client sent first got terminated by a
            // certificate it may not trust — the failure this migration exists to stop.
            if Self.migrateSeededWildcard(&saved, defaults: defaults) {
                self.scope = Mutex(saved)
                Self.persist(saved, to: defaults, key: storageKey)
                return
            }
            self.scope = Mutex(saved)
        } else {
            self.scope = Mutex(scope)
        }
    }

    /// Marks the migration as *attempted*, so it runs once per install whatever the
    /// outcome — a fresh install included, or the wildcard would come back the first
    /// time someone deliberately typed one and relaunched.
    static let whitelistMigrationKey = "com.loom.sslScopeWhitelistMigrated"
    /// Marks it as having *changed something*. Two keys rather than one because the
    /// app announces from this one: a fresh install attempts the migration and
    /// changes nothing, and telling that user their scope was rewritten would be a
    /// notice about an event that never happened.
    static let whitelistMigrationAppliedKey = "com.loom.sslScopeWhitelistMigrationApplied"

    /// Drop an `include` that is *exactly* the seeded wildcard, once.
    ///
    /// `["*"]` was never a choice — `toggleSSLTapped` wrote it the first time anyone
    /// switched HTTPS interception on, and the stored value cannot tell a seed from a
    /// decision. So the migration is deliberately narrow: only that exact shape, and
    /// only while the marker is absent. `["*", "api.example.com"]`, `["*.corp"]` or a
    /// hand-typed `*` re-added *after* the migration all stand — someone who types a
    /// wildcard into a whitelist means it.
    ///
    /// Returns whether it changed anything, so the caller persists exactly once.
    private static func migrateSeededWildcard(_ scope: inout SSLScope, defaults: UserDefaults) -> Bool {
        guard !defaults.bool(forKey: whitelistMigrationKey) else { return false }
        defaults.set(true, forKey: whitelistMigrationKey)
        guard scope.include == ["*"] else { return false }
        scope.include = []
        defaults.set(true, forKey: whitelistMigrationAppliedKey)
        Log.tls.error("""
        SSL scope migrated to a whitelist: the seeded include "*" was dropped, so \
        nothing is decrypted until a host is added. Traffic is still observed and \
        listed as tunnelled.
        """)
        return true
    }

    func snapshot() -> SSLScope {
        scope.withLock { $0 }
    }

    func update(_ newScope: SSLScope) {
        scope.withLock {
            $0 = newScope
            // Enqueued under the lock — see `persistQueue`.
            persistQueue.async { [weak self] in self?.persist(newScope) }
        }
    }

    /// Read-modify-write the scope under one acquisition of the lock.
    ///
    /// The alternative — `snapshot()`, edit, `update()` — is a lost-update race
    /// between the two independent writers this engine has: the human on the console
    /// and an agent on `intercept_host`. Losing one there means a host silently
    /// stops being intercepted, which is exactly the invisible failure the
    /// tunnelled-host surface exists to remove.
    func mutate<T>(_ body: (inout SSLScope) -> T) -> T {
        scope.withLock {
            let result = body(&$0)
            let updated = $0
            // Enqueued under the lock — see `persistQueue`.
            persistQueue.async { [weak self] in self?.persist(updated) }
            return result
        }
    }

    /// Block until every queued write has run — quit handler, and any test that
    /// reads the defaults straight after updating.
    func flush() {
        persistQueue.sync {}
    }

    func shouldIntercept(host: String) -> Bool {
        snapshot().shouldIntercept(host: host)
    }

    // MARK: - Persistence

    private func persist(_ scope: SSLScope) {
        guard let defaults else { return }
        Self.persist(scope, to: defaults, key: storageKey)
    }

    /// Static so the migration can write before `self` is fully initialized.
    private static func persist(_ scope: SSLScope, to defaults: UserDefaults, key: String) {
        do {
            defaults.set(try JSONEncoder().encode(scope), forKey: key)
        } catch {
            Log.tls.error("SSL scope persist failed; interception settings may not survive relaunch: \(String(describing: error))")
        }
    }

    private static func load(from defaults: UserDefaults, key: String) -> SSLScope? {
        guard let data = defaults.data(forKey: key) else { return nil }
        do {
            return try JSONDecoder().decode(SSLScope.self, from: data)
        } catch {
            // Falls back to the default (disabled) scope, i.e. HTTPS stops being
            // intercepted and nothing gets captured — the user would just see an
            // empty list, with no hint why.
            Log.tls.error("Stored SSL scope is undecodable; falling back to interception disabled: \(String(describing: error))")
            return nil
        }
    }
}
