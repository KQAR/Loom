import Foundation
import LoomSharedModels
import NIOCore

/// Turns a failed listener bind into something the operator can act on.
///
/// It exists because of what the un-translated version says. `NIOCore.IOError` is
/// not a `LocalizedError`, so `error.localizedDescription` renders it as **"The
/// operation couldn't be completed. (NIOCore.IOError error 1.)"** — no port, no
/// reason, and the trailing `1` is Foundation's own numbering rather than the
/// `errno` it looks like. That string reached the phone-onboarding popover on the
/// one failure the operator can fix in ten seconds: another proxy already holding
/// the port.
///
/// The measured case, and the reason this is worth a type: Whistle was listening on
/// `*:9090` (IPv6 wildcard). Loom's `127.0.0.1:9090` bind succeeded — the two do not
/// collide — so the proxy came up looking healthy, and only the rebind to `0.0.0.0`
/// that phone onboarding needs hit `EADDRINUSE`.
enum BindDiagnosis {
    /// What went wrong binding `host:port`, named.
    static func describe(_ error: Error, host: String, port: Int) -> String {
        let address = "\(host):\(port)"
        // Already in the operator's words — wrapping it again produced
        // "could not listen on 0.0.0.0:9099: listenerUnavailable(\"…\")", i.e. this
        // type's whole purpose applied to its own output. The short-circuit belongs
        // here as well as in `error(_:)`, which is where it was.
        if let control = error as? ProxyControlError { return control.message }
        guard let io = error as? IOError else {
            return "could not listen on \(address): \(error)"
        }
        switch io.errnoCode {
        case EADDRINUSE:
            return """
                \(address) is already in use — another proxy (Charles, Proxyman, Whistle, mitmproxy) \
                or a dev server is listening there. Change Loom's port, or stop the other one.
                """
        case EACCES, EPERM:
            return "\(address) is not permitted — ports below 1024 need root, which Loom deliberately does not take."
        case EADDRNOTAVAIL:
            return "\(address) is not an address on this machine — the interface may have gone away."
        default:
            return "could not listen on \(address): \(io)"
        }
    }

    /// The same, as the error every caller should see instead of NIO's.
    static func error(_ error: Error, host: String, port: Int) -> ProxyControlError {
        // A `ProxyControlError` has already been through here (or is a different
        // failure entirely) — wrapping it again would bury its own message.
        if let control = error as? ProxyControlError { return control }
        return .listenerUnavailable(describe(error, host: host, port: port))
    }
}
