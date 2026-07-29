import Foundation
import LoomSharedModels

/// A thread-safe holder for the SSL-proxying scope, shared between the actor
/// (which updates it) and the NIO handlers (which read a snapshot synchronously
/// on each CONNECT). Kept off the actor so the event loop never has to `await`.
///
/// The scope is persisted (UserDefaults) so HTTPS interception survives an app
/// relaunch — otherwise every launch resets to disabled, every HTTPS connection
/// falls back to a blind tunnel, and nothing gets captured.
final class InterceptionConfig: @unchecked Sendable {
    private let lock = NSLock()
    private var scope: SSLScope
    private let defaults: UserDefaults?
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
        if let defaults, let saved = Self.load(from: defaults, key: storageKey) {
            self.scope = saved
        } else {
            self.scope = scope
        }
    }

    func snapshot() -> SSLScope {
        lock.lock()
        defer { lock.unlock() }
        return scope
    }

    func update(_ newScope: SSLScope) {
        lock.lock()
        scope = newScope
        persistQueue.async { [weak self] in self?.persist(newScope) }
        lock.unlock()
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
        do {
            defaults.set(try JSONEncoder().encode(scope), forKey: storageKey)
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
