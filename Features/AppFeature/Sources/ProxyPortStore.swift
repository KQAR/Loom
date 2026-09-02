import Foundation
import LoomSharedModels

/// Persists the port the proxy listens on, so a choice survives relaunch. Absent
/// key → 9090, which is what every doc, the skill and the empty state's `curl -x`
/// hint have always printed. Side-effecting, so the reducer touches it only from
/// effects (same shape as `LANCaptureStore`).
enum ProxyPortStore {
    static let defaultPort = 9090
    private static let key = "com.loom.proxyPort"

    static func load() -> Int {
        let stored = UserDefaults.standard.integer(forKey: key)
        return ListenPortRules.refusal(for: stored) == nil ? stored : defaultPort
    }

    static func save(_ port: Int) {
        UserDefaults.standard.set(port, forKey: key)
    }
}
