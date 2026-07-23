import Foundation

/// Persists whether LAN device connection is allowed (proxy bound to `0.0.0.0`
/// + provisioning server), so the choice survives relaunches. Defaults to **on**
/// when unset — a fresh install lets phones on the same Wi-Fi connect out of the
/// box. Side-effecting, so the reducer touches it only from effects.
enum LANCaptureStore {
    private static let key = "com.loom.lanCaptureEnabled"

    static func load() -> Bool {
        // Absent key → default on; otherwise the stored choice.
        UserDefaults.standard.object(forKey: key) == nil
            ? true
            : UserDefaults.standard.bool(forKey: key)
    }

    static func save(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: key)
    }
}
