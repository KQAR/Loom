import Foundation

/// Persists the user's pinned hosts and apps (UserDefaults) so pins survive
/// relaunches. Keyed by host string / app grouping key. Side-effecting, so the
/// reducer touches it only from effects — never inline in the reducer body.
enum PinsStore {
    private static let hostsKey = "com.loom.pinnedHosts"
    private static let appsKey = "com.loom.pinnedApps"

    static func load() -> (hosts: Set<String>, apps: Set<String>) {
        let hosts = (UserDefaults.standard.array(forKey: hostsKey) as? [String]) ?? []
        let apps = (UserDefaults.standard.array(forKey: appsKey) as? [String]) ?? []
        return (Set(hosts), Set(apps))
    }

    static func save(hosts: Set<String>, apps: Set<String>) {
        UserDefaults.standard.set(Array(hosts), forKey: hostsKey)
        UserDefaults.standard.set(Array(apps), forKey: appsKey)
    }
}
