import Foundation

/// The device a proxied request came from, identified by the connection's remote
/// IP. Distinct from `SourceApp` (which is *local* process attribution via
/// libproc and is meaningful only for loopback traffic): a phone on the LAN has
/// no local PID, so it's identified by its address and typed from its User-Agent.
///
/// AppKit-free so engine modules can build it. The UI groups flows by device the
/// same way it groups by host/app.
public struct SourceDevice: Equatable, Codable, Sendable, Hashable {
    public enum Kind: String, Codable, Sendable, Hashable {
        /// This Mac (loopback) — the app/CLI running locally.
        case local
        /// A LAN device (e.g. a phone) pointing its proxy at this machine.
        case lan
    }

    /// Remote IP of the connection — the stable device identity.
    public var ip: String
    public var kind: Kind
    /// OS family parsed from the User-Agent (`iOS`, `Android`, `macOS`, …). Nil
    /// when no UA was seen or it couldn't be classified.
    public var platform: String?
    /// Client/app/browser parsed from the User-Agent (`Safari`, `Chrome`, `curl`, …).
    public var client: String?

    public init(ip: String, kind: Kind, platform: String? = nil, client: String? = nil) {
        self.ip = ip
        self.kind = kind
        self.platform = platform
        self.client = client
    }

    /// Stable grouping key: the IP (one device = one address).
    public var groupingKey: String { ip }

    /// Last octet of the IP, to disambiguate same-type devices, e.g. `.37`.
    public var ipSuffix: String {
        "." + (ip.split(separator: ".").last.map(String.init) ?? ip)
    }

    /// Auto label (before any user alias): `This Mac`, or `<platform> · <ip suffix>`
    /// so two same-type LAN devices stay distinct. A user-set alias is layered on
    /// top in the UI (see `DeviceAliasStore`).
    public var displayName: String {
        switch kind {
        case .local: return "This Mac"
        case .lan: return "\(platform ?? "Device") \(ipSuffix)"
        }
    }

    /// Short type descriptor like `Safari (iOS)` / `Chrome` / nil if unknown.
    public var typeSummary: String? {
        switch (platform, client) {
        case let (p?, c?): return "\(c) (\(p))"
        case let (p?, nil): return p
        case let (nil, c?): return c
        case (nil, nil): return nil
        }
    }

    /// Classify a loopback vs LAN address (handles IPv6 loopback + v4-mapped).
    public static func kind(forIP ip: String) -> Kind {
        if ip == "127.0.0.1" || ip == "::1" || ip.hasPrefix("127.")
            || ip.hasSuffix("::ffff:127.0.0.1") || ip == "0.0.0.0" {
            return .local
        }
        return .lan
    }
}

/// One device that has sent traffic through the proxy, with how much and when —
/// what `list_devices` / the sidebar's Devices section show.
public struct DeviceSummary: Equatable, Codable, Sendable, Hashable, Identifiable {
    public var device: SourceDevice
    public var flowCount: Int
    public var lastActive: Date

    public init(device: SourceDevice, flowCount: Int, lastActive: Date) {
        self.device = device
        self.flowCount = flowCount
        self.lastActive = lastActive
    }

    public var id: String { device.groupingKey }
}
