import Foundation

/// One network service's proxy settings (HTTP / HTTPS / SOCKS + bypass list),
/// as read from / written to `networksetup`. Codable so the helper can persist a
/// backup to disk and a watchdog subprocess can restore it after a crash.
public struct ProxyServiceState: Codable, Equatable, Sendable {
    public var service: String
    public var httpEnabled: Bool
    public var httpHost: String
    public var httpPort: Int
    public var httpsEnabled: Bool
    public var httpsHost: String
    public var httpsPort: Int
    public var socksEnabled: Bool
    public var socksHost: String
    public var socksPort: Int
    public var bypassDomains: [String]

    public init(
        service: String,
        httpEnabled: Bool = false, httpHost: String = "", httpPort: Int = 0,
        httpsEnabled: Bool = false, httpsHost: String = "", httpsPort: Int = 0,
        socksEnabled: Bool = false, socksHost: String = "", socksPort: Int = 0,
        bypassDomains: [String] = []
    ) {
        self.service = service
        self.httpEnabled = httpEnabled; self.httpHost = httpHost; self.httpPort = httpPort
        self.httpsEnabled = httpsEnabled; self.httpsHost = httpsHost; self.httpsPort = httpsPort
        self.socksEnabled = socksEnabled; self.socksHost = socksHost; self.socksPort = socksPort
        self.bypassDomains = bypassDomains
    }

    /// True when HTTP+HTTPS both point at Loom on `127.0.0.1:port` — used by the
    /// watchdog to decide whether a stale override still belongs to us before restoring.
    public func pointsAtLoom(port: Int) -> Bool {
        httpEnabled && httpHost == "127.0.0.1" && httpPort == port
            && httpsEnabled && httpsHost == "127.0.0.1" && httpsPort == port
    }
}

/// A full backup of every enabled service's proxy settings, plus which app PID
/// owns the override, so the helper (or its watchdog) can restore exactly.
public struct ProxyBackup: Codable, Equatable, Sendable {
    public var services: [ProxyServiceState]
    public var ownerPID: Int32
    public var loomPort: Int
    public var createdAt: Date

    public init(services: [ProxyServiceState], ownerPID: Int32, loomPort: Int, createdAt: Date) {
        self.services = services
        self.ownerPID = ownerPID
        self.loomPort = loomPort
        self.createdAt = createdAt
    }
}

/// Pure parsing/validation for the privileged proxy code, split out so it can be
/// unit-tested without root or `networksetup`.
public enum SystemProxyParsing {
    /// Parse `networksetup -getwebproxy <svc>` output into `(enabled, host, port)`.
    /// Output looks like:
    /// ```
    /// Enabled: Yes
    /// Server: 127.0.0.1
    /// Port: 9090
    /// ```
    public static func parseProxyOutput(_ output: String) -> (enabled: Bool, host: String, port: Int) {
        var enabled = false
        var host = ""
        var port = 0
        for line in output.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let value = Self.value(of: "Enabled", in: trimmed) {
                enabled = value.lowercased() == "yes"
            } else if let value = Self.value(of: "Server", in: trimmed) {
                host = value
            } else if let value = Self.value(of: "Port", in: trimmed) {
                port = Int(value) ?? 0
            }
        }
        return (enabled, host, port)
    }

    /// Parse `networksetup -listallnetworkservices` output. The first line is a
    /// disclaimer; a `*` prefix marks a disabled service (excluded).
    public static func parseServiceList(_ output: String) -> [String] {
        output
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .filter { !$0.lowercased().contains("an asterisk") }
            .filter { !$0.hasPrefix("*") } // disabled service
    }

    private static func value(of key: String, in line: String) -> String? {
        let prefix = "\(key):"
        guard line.hasPrefix(prefix) else { return nil }
        return String(line.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
    }

    /// Interpret an `SCDynamicStoreCopyProxies`-shaped dictionary: true when the
    /// *effective* system proxy routes both HTTP and HTTPS through `host:port`.
    /// Pure so it can be unit-tested; the caller bridges the CF dictionary.
    public static func effectiveProxiesPoint(at host: String, port: Int, in proxies: [String: Any]) -> Bool {
        func enabled(_ key: String) -> Bool { (proxies[key] as? Int ?? 0) == 1 }
        return enabled("HTTPEnable")
            && proxies["HTTPProxy"] as? String == host
            && proxies["HTTPPort"] as? Int == port
            && enabled("HTTPSEnable")
            && proxies["HTTPSProxy"] as? String == host
            && proxies["HTTPSPort"] as? Int == port
    }

    /// Sanitize a bypass-domain list before it is handed to `networksetup`:
    /// trim, drop empties, reject entries with shell metacharacters or whitespace
    /// (defense-in-depth even though we exec without a shell), and de-duplicate.
    public static func sanitizeBypassDomains(_ domains: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        let forbidden = CharacterSet(charactersIn: " \t\n;|&`$<>()\"'\\")
        for raw in domains {
            let d = raw.trimmingCharacters(in: .whitespaces)
            guard !d.isEmpty else { continue }
            guard d.rangeOfCharacter(from: forbidden) == nil else { continue }
            guard seen.insert(d).inserted else { continue }
            out.append(d)
        }
        return out
    }
}
