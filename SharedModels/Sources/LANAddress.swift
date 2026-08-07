import Darwin
import Foundation

/// Resolves this machine's primary LAN IPv4 address (prefers `en0`/`en1`) — the
/// address a phone points its proxy at, embedded in the provisioning QR.
///
/// It lives in the base layer because **both** sides need the same answer and a
/// disagreement is a real defect, not a cosmetic one. The engine picks the
/// address it publishes in `PhoneOnboardingInfo`; the app watches for the address
/// changing and republishes when it does, which is a comparison between the two.
/// This was a byte-for-byte duplicate in `AppFeature` (`LocalIP.primaryIPv4`)
/// until that comparison needed the two copies to agree by construction rather
/// than by both having been edited together.
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
            // Pointer overload, not the array one: the latter is deprecated in Swift 6
            // in favour of an explicit decode, and `getnameinfo` already NUL-terminates.
            let ip = host.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
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
