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
        lock.unlock()
        persist(newScope)
    }

    func shouldIntercept(host: String) -> Bool {
        snapshot().shouldIntercept(host: host)
    }

    // MARK: - Persistence

    private func persist(_ scope: SSLScope) {
        guard let defaults else { return }
        if let data = try? JSONEncoder().encode(scope) {
            defaults.set(data, forKey: storageKey)
        }
    }

    private static func load(from defaults: UserDefaults, key: String) -> SSLScope? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(SSLScope.self, from: data)
    }
}
