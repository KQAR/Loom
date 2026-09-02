import Darwin
import Foundation

/// Whether something else already holds `127.0.0.1:port`.
///
/// **A wildcard bind does not collide with a loopback one**, and that is not a
/// theoretical gap — it is how the two proxies on this machine ended up sharing a
/// port number. `SO_REUSEADDR` lets `0.0.0.0:9099` and `127.0.0.1:9099` coexist, the
/// kernel routes each connection to the *most specific* listener, and the result is
/// a bind that succeeds, a status that says the port is listening, and every local
/// client silently answered by the other process. Measured: `curl -x
/// 127.0.0.1:9099` timed out against the squatter while the LAN address served Loom
/// normally.
///
/// So a wildcard bind asks this first. The probe binds loopback **without**
/// `SO_REUSEADDR` — the one configuration that refuses to share — and releases it
/// immediately. A listening socket does not enter `TIME_WAIT` when it closes (only
/// connections do), so Loom's own just-stopped listener cannot make this a false
/// positive.
///
/// There is a TOCTOU window between the probe and the real bind, and it is accepted
/// deliberately: the alternative is not probing at all, which is the failure above.
enum LoopbackProbe {
    static func isTaken(port: Int) -> Bool {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return false } // can't tell — don't invent a conflict
        defer { close(descriptor) }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(UInt16(port).bigEndian)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")

        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        // Only `EADDRINUSE` is an answer. Anything else (a permission error on a
        // privileged port, an address that isn't there) is a different question, and
        // the real bind is about to ask it properly.
        return result != 0 && errno == EADDRINUSE
    }
}
