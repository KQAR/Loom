import Darwin
import Foundation

/// Resolves this machine's primary LAN IPv4 address (prefers `en0`/`en1`) so the
/// engine can tell a phone which address to point its proxy at and embed it in
/// the provisioning QR. Lives in the engine (not the UI) because phone
/// onboarding is an engine capability any embedder can reuse.
public enum LANAddress {
    /// The primary LAN IPv4, or `nil` if the machine has no usable non-loopback
    /// IPv4 interface (e.g. offline).
    public static func primaryIPv4() -> String? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }

        var preferred: String? // en0 / en1 (Wi-Fi / primary Ethernet)
        var fallback: String?  // any other non-loopback IPv4

        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let flags = Int32(ptr.pointee.ifa_flags)
            guard (flags & (IFF_UP | IFF_RUNNING)) == (IFF_UP | IFF_RUNNING),
                  (flags & IFF_LOOPBACK) == 0,
                  let addr = ptr.pointee.ifa_addr,
                  addr.pointee.sa_family == UInt8(AF_INET)
            else { continue }

            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(addr, socklen_t(addr.pointee.sa_len),
                              &host, socklen_t(host.count),
                              nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let ip = String(cString: host)
            let name = String(cString: ptr.pointee.ifa_name)
            if name == "en0" || name == "en1" {
                preferred = preferred ?? ip
            } else {
                fallback = fallback ?? ip
            }
        }
        return preferred ?? fallback
    }
}
