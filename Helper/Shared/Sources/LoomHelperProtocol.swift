import Foundation

/// What the root helper will do on request — the whole of it.
///
/// **The interface takes parameters, never a script.** The daemon builds every
/// command it runs from `SystemProxyScripts` on its own side; nothing a caller
/// sends is interpolated into a shell. This is the difference between "any local
/// process can toggle the system proxy" and "any local process gets arbitrary
/// root code", and with an ad-hoc signature (see `HelperRequirement`) the caller
/// cannot be verified, so it is the boundary that actually holds.
///
/// For the same reason the host is **not** a parameter: the daemon hardcodes
/// `127.0.0.1`, so this surface cannot be used to point the machine's traffic at
/// someone else's server.
///
/// **Deliberately absent: system-domain CA trust.** A root daemon that installs a
/// trusted root certificate, reachable by any local process, is machine-wide MITM
/// for anything on this Mac. That stays a manual `sudo security add-trusted-cert`
/// until Loom is signed with an identity that makes the caller check real. The
/// operations here are ones an admin account can already perform silently
/// (`networksetup`) or whose worst case is a reversible local denial of service
/// (the pf QUIC block).
@objc public protocol LoomHelperProtocol {
    /// Point the system proxy at `127.0.0.1:<port>` and block QUIC, or undo both.
    ///
    /// - Parameters:
    ///   - enabled: on or off.
    ///   - port: Loom's HTTP proxy port. Validated by the daemon.
    ///   - restoreQUIC: on a disable, whether there is a pf block to undo. The app
    ///     owns that bookkeeping (`com.loom.quicBlocked`); a caller that gets it
    ///     wrong only ever causes an idempotent no-op restore, which is the safe
    ///     direction to be wrong in.
    ///   - reply: `ok`, and a message when there is something the human must know.
    func applySystemProxy(
        enabled: Bool,
        port: Int,
        restoreQUIC: Bool,
        withReply reply: @escaping (Bool, String?) -> Void
    )

    /// Undo a pf QUIC block with no proxy attached to it — the crash-recovery path.
    /// Idempotent; safe to call when nothing is blocked.
    func restoreQUICBlock(withReply reply: @escaping (Bool, String?) -> Void)

    /// The daemon's interface version, for detecting an app talking to a stale
    /// daemon. Also the cheapest possible liveness probe.
    func helperVersion(withReply reply: @escaping (Int) -> Void)
}
