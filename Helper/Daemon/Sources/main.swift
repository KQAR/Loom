import Foundation
import LoomHelperShared
import os

/// Loom's privileged helper: a root LaunchDaemon whose entire job is to run the
/// system-proxy and pf (QUIC) work that `/dev/pf` makes impossible un-escalated,
/// so toggling the system proxy stops costing an admin password every time.
///
/// Registered by the app through `SMAppService.daemon(plistName:)`, approved once
/// by the human in System Settings → Login Items, and then resident. It holds no
/// state, keeps no files of its own, and does exactly the three things in
/// `LoomHelperProtocol` — see that file for what is deliberately *not* here and
/// why the interface takes parameters rather than a script.
private let log = Logger(subsystem: "com.loom", category: "helper")

final class HelperService: NSObject, LoomHelperProtocol {
    /// The daemon decides where the proxy points. A caller cannot redirect this
    /// machine's traffic to a host of its choosing — that is the single most
    /// valuable thing this surface could be abused for, so it isn't on it.
    private static let proxyHost = "127.0.0.1"

    func applySystemProxy(
        enabled: Bool,
        port: Int,
        restoreQUIC: Bool,
        withReply reply: @escaping (Bool, String?) -> Void
    ) {
        guard (1 ... 65535).contains(port) else {
            log.error("refused applySystemProxy: port \(port, privacy: .public) out of range")
            reply(false, "Port \(port) is out of range.")
            return
        }
        let script = enabled
            ? SystemProxyScripts.enable(host: Self.proxyHost, port: port)
            : SystemProxyScripts.disable(restoreQUIC: restoreQUIC)
        let (status, stderr) = Shell.run(script)
        if status == 0 {
            log.notice("system proxy \(enabled ? "enabled" : "disabled", privacy: .public) on port \(port, privacy: .public)")
            reply(true, nil)
        } else {
            // Same honesty rule as the un-escalated path: the proxy half may well
            // have landed while the pf half failed, and a caller that hears only
            // "failed" will tell the human the wrong thing.
            log.error("system proxy change exited \(status, privacy: .public): \(stderr, privacy: .public)")
            reply(false, stderr.isEmpty ? "The proxy change exited \(status)." : stderr)
        }
    }

    func restoreQUICBlock(withReply reply: @escaping (Bool, String?) -> Void) {
        let (status, stderr) = Shell.run(SystemProxyScripts.restoreQUICOnly)
        if status == 0 {
            log.notice("QUIC block restored")
            reply(true, nil)
        } else {
            log.error("QUIC restore exited \(status, privacy: .public): \(stderr, privacy: .public)")
            reply(false, stderr.isEmpty ? "The QUIC restore exited \(status)." : stderr)
        }
    }

    func helperVersion(withReply reply: @escaping (Int) -> Void) {
        reply(HelperConstants.interfaceVersion)
    }
}

enum Shell {
    /// `-c` with the script inline: nothing is staged on disk, so there is no file
    /// for another process to swap between write and execution. The same reasoning
    /// as `SystemProxyApplier`'s osascript path, which inlines rather than stages
    /// for exactly this reason — and it matters more here, since this side is root.
    static func run(_ script: String) -> (status: Int32, stderr: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script]
        let errPipe = Pipe()
        process.standardError = errPipe
        process.standardOutput = Pipe()
        do {
            try process.run()
        } catch {
            return (-1, error.localizedDescription)
        }
        // Read before waiting: a script that fills the pipe buffer would otherwise
        // block forever on write while we block forever on exit.
        let stderr = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        process.waitUntilExit()
        return (process.terminationStatus, stderr.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

final class ListenerDelegate: NSObject, NSXPCListenerDelegate {
    private let service = HelperService()

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        // The caller check itself is `setConnectionCodeSigningRequirement` below —
        // enforced by XPC before this is ever called, which is why it isn't
        // re-implemented here with audit tokens.
        log.debug("accepted a connection from pid \(connection.processIdentifier, privacy: .public)")
        connection.exportedInterface = NSXPCInterface(with: LoomHelperProtocol.self)
        connection.exportedObject = service
        connection.resume()
        return true
    }
}

let delegate = ListenerDelegate()
let listener = NSXPCListener(machServiceName: HelperConstants.machServiceName)
listener.delegate = delegate

// As strong as this build's signature allows: with a real identity the caller must
// carry our team, with an ad-hoc one only the bundle identifier can be checked (and
// that is forgeable). `HelperRequirement` documents the consequence in full; the
// short version is that the ad-hoc case is why this daemon's surface is limited to
// operations an admin account could already perform.
let requirement = HelperRequirement.forClient(teamIdentifier: HelperRequirement.selfTeamIdentifier())
listener.setConnectionCodeSigningRequirement(requirement)
log.notice("helper listening, client requirement: \(requirement, privacy: .public)")

listener.resume()
dispatchMain()
