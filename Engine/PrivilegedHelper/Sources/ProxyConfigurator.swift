import Foundation
import SharedModels
import os

/// Reads and writes the system proxy across every enabled network service via
/// `networksetup`, using the shared pure parsers in `SystemProxyParsing`. All IO
/// goes through the validated `ProcessRunner`.
enum ProxyConfigurator {
    private static let logger = Logger(subsystem: HelperIdentity.logSubsystem, category: "ProxyConfigurator")

    static func enabledServices() -> [String] {
        guard let result = try? ProcessRunner.run(HelperPaths.networkSetup, ["-listallnetworkservices"]),
              result.ok
        else { return [] }
        return SystemProxyParsing.parseServiceList(result.stdout)
    }

    static func captureState(of service: String) -> ProxyServiceState {
        let http = read(["-getwebproxy", service])
        let https = read(["-getsecurewebproxy", service])
        let socks = read(["-getsocksfirewallproxy", service])
        let bypass = readBypass(service)
        return ProxyServiceState(
            service: service,
            httpEnabled: http.enabled, httpHost: http.host, httpPort: http.port,
            httpsEnabled: https.enabled, httpsHost: https.host, httpsPort: https.port,
            socksEnabled: socks.enabled, socksHost: socks.host, socksPort: socks.port,
            bypassDomains: bypass
        )
    }

    /// Point HTTP+HTTPS at `127.0.0.1:port` for every enabled service and return
    /// the pre-override snapshot for backup.
    static func applyOverride(port: Int) throws -> [ProxyServiceState] {
        let services = enabledServices()
        var snapshots: [ProxyServiceState] = []
        for service in services {
            snapshots.append(captureState(of: service))
            try ProcessRunner.run(HelperPaths.networkSetup, ["-setwebproxy", service, "127.0.0.1", String(port)])
            try ProcessRunner.run(HelperPaths.networkSetup, ["-setwebproxystate", service, "on"])
            try ProcessRunner.run(HelperPaths.networkSetup, ["-setsecurewebproxy", service, "127.0.0.1", String(port)])
            try ProcessRunner.run(HelperPaths.networkSetup, ["-setsecurewebproxystate", service, "on"])
        }
        return snapshots
    }

    static func restore(_ services: [ProxyServiceState]) throws {
        for state in services {
            try apply(state)
        }
    }

    static func apply(_ state: ProxyServiceState) throws {
        let s = state.service
        try ProcessRunner.run(HelperPaths.networkSetup, ["-setwebproxystate", s, "off"])
        try ProcessRunner.run(HelperPaths.networkSetup, ["-setsecurewebproxystate", s, "off"])
        try ProcessRunner.run(HelperPaths.networkSetup, ["-setsocksfirewallproxystate", s, "off"])
        if state.httpEnabled {
            try ProcessRunner.run(HelperPaths.networkSetup, ["-setwebproxy", s, state.httpHost, String(state.httpPort)])
            try ProcessRunner.run(HelperPaths.networkSetup, ["-setwebproxystate", s, "on"])
        }
        if state.httpsEnabled {
            try ProcessRunner.run(HelperPaths.networkSetup, ["-setsecurewebproxy", s, state.httpsHost, String(state.httpsPort)])
            try ProcessRunner.run(HelperPaths.networkSetup, ["-setsecurewebproxystate", s, "on"])
        }
        if state.socksEnabled {
            try ProcessRunner.run(HelperPaths.networkSetup, ["-setsocksfirewallproxy", s, state.socksHost, String(state.socksPort)])
            try ProcessRunner.run(HelperPaths.networkSetup, ["-setsocksfirewallproxystate", s, "on"])
        }
        try applyBypass(state.bypassDomains, to: s)
    }

    /// `(isOverriddenByLoom, port)` — true when any enabled service points at Loom.
    static func status(loomPort: Int) -> (Bool, Int) {
        for service in enabledServices() where captureState(of: service).pointsAtLoom(port: loomPort) {
            return (true, loomPort)
        }
        return (false, 0)
    }

    // MARK: Private

    private static func read(_ args: [String]) -> (enabled: Bool, host: String, port: Int) {
        guard let result = try? ProcessRunner.run(HelperPaths.networkSetup, args), result.ok else {
            return (false, "", 0)
        }
        return SystemProxyParsing.parseProxyOutput(result.stdout)
    }

    private static func readBypass(_ service: String) -> [String] {
        guard let result = try? ProcessRunner.run(HelperPaths.networkSetup, ["-getproxybypassdomains", service]),
              result.ok
        else { return [] }
        return result.stdout
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && $0.lowercased() != "there aren't any bypass domains set on this network service." }
    }

    private static func applyBypass(_ domains: [String], to service: String) throws {
        if domains.isEmpty {
            try ProcessRunner.run(HelperPaths.networkSetup, ["-setproxybypassdomains", service, "Empty"])
        } else {
            try ProcessRunner.run(HelperPaths.networkSetup, ["-setproxybypassdomains", service] + domains)
        }
    }
}
