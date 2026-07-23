import Foundation

/// Persists user-assigned device aliases (UserDefaults), keyed by the device's
/// remote IP. iOS won't hand out a real device name over the network, so the
/// human labels a device once ("Jarvis-iPhone") and it sticks across relaunches.
/// Side-effecting — the reducer touches it only from effects.
enum DeviceAliasStore {
    private static let key = "com.loom.deviceAliases"

    static func load() -> [String: String] {
        (UserDefaults.standard.dictionary(forKey: key) as? [String: String]) ?? [:]
    }

    static func save(_ aliases: [String: String]) {
        UserDefaults.standard.set(aliases, forKey: key)
    }
}
