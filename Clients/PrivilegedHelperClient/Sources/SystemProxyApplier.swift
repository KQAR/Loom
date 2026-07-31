import Foundation
import SystemConfiguration
import LoomHelperProtocol
import LoomSharedModels

/// Sets the macOS system HTTP+HTTPS proxy without a privileged helper.
///
/// Strategy: run `networksetup` directly first — for admin users that needs **no
/// authentication at all**, so toggling is silent. The result is verified against
/// the effective proxy state (`SCDynamicStoreCopyProxies`); only if it didn't
/// stick (non-admin user) do we retry the same script through
/// `osascript … with administrator privileges`, which prompts once.
/// (The XPC helper remains the future option for non-admin, crash-safe installs.)
///
/// Must run OFF the main thread — the fallback auth prompt is modal.
enum SystemProxyApplier {
    /// App-side record of whether the QUIC (pf) block is in place from a fully
    /// successful enable. pf state can't be read back without root, so this is
    /// what decides whether a disable has pf work to do at all — when it doesn't,
    /// the disable script carries no pfctl and an admin user's toggle-off stays
    /// prompt-free.
    static let quicBlockedKey = "com.loom.quicBlocked"

    static func apply(enabled: Bool, host: String, port: Int, defaults: UserDefaults = .standard) -> (Bool, String?) {
        let restoreQUIC = !enabled && defaults.bool(forKey: quicBlockedKey)
        let script = enabled ? enableScript(host: host, port: port) : disableScript(restoreQUIC: restoreQUIC)

        // 1) Direct, silent path (works for admin users): feed the script to sh on
        //    stdin-equivalent `-c`, never touching disk.
        //
        //    The exit status matters as much as the proxy check: the pf (QUIC)
        //    section needs root even for an admin user, and its failures are how
        //    the script says "the proxy landed but QUIC did not". Ignoring it —
        //    the old behavior — meant admin users never blocked QUIC at all while
        //    the panel claimed otherwise, so browser HTTP/3 silently bypassed
        //    Loom. A script with no pf work (disable with nothing to restore)
        //    still exits 0 and keeps this path silent.
        let (directStatus, _) = run("/bin/sh", ["-c", script])
        if directStatus == 0, verified(enabled: enabled, port: port) {
            defaults.set(enabled, forKey: quicBlockedKey)
            return (true, nil)
        }

        // The direct run may still have applied the proxy half (admin user, pf
        // half failed) — remembered so a cancelled prompt below can report an
        // honest partial success instead of a failure that isn't one.
        let proxyLandedSilently = verified(enabled: enabled, port: port, attempts: 1)

        // 2) Fallback: the SAME script inlined into one admin prompt. Inlining the
        //    text (rather than writing a script file and running it as root) closes
        //    a privilege-escalation TOCTOU — a same-uid process could otherwise
        //    swap the staged file between our write and the privileged execution,
        //    turning Loom's authorization dialog into arbitrary root code.
        let osascript = "do shell script \(appleScriptString(script)) with administrator privileges"
        let (status, stderr) = run("/usr/bin/osascript", ["-e", osascript])
        if status == 0, verified(enabled: enabled, port: port) {
            defaults.set(enabled, forKey: quicBlockedKey)
            return (true, nil)
        }
        if stderr.contains("User canceled") || stderr.contains("-128") {
            if proxyLandedSilently {
                // The proxy is in the requested state; only the root-only pf work
                // is missing. Say exactly what that means rather than failing.
                if enabled {
                    defaults.set(false, forKey: quicBlockedKey)
                    return (true, "Proxy is on, but QUIC (HTTP/3) stays unblocked without authorization — browser traffic may bypass capture.")
                }
                // quicBlockedKey stays true so the next disable retries the restore.
                return (true, "Proxy is off, but the QUIC firewall rule needs authorization to remove — HTTP/3 stays blocked until then.")
            }
            return (false, "Authorization cancelled.")
        }
        return (false, stderr.isEmpty ? "networksetup failed" : stderr.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Where this Mac's traffic currently goes. Reading needs no privileges. Used for
    /// the boot-time UI sync, post-apply verification, and the quit-time cleanup
    /// decision — one definition, so the human, the agent and the quit path can't
    /// disagree about whether Loom holds the proxy.
    static func routing(loomPort: Int) -> SystemProxyRouting {
        SystemProxyMonitor.snapshot().routing(loomPort: loomPort)
    }

    /// Quote a shell script as an AppleScript string literal for `do shell script`.
    /// Escape backslashes first, then double quotes; osascript unescapes it back to
    /// the exact bytes and runs them via `/bin/sh -c`.
    static func appleScriptString(_ s: String) -> String {
        let escaped = s
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    /// Whether the *effective* system proxy currently routes HTTP+HTTPS through Loom.
    static func isPointing(port: Int) -> Bool {
        routing(loomPort: port) == .loom
    }

    // MARK: - Internals

    /// The dynamic store lags a written config by a beat; poll briefly.
    ///
    /// Note this checks "does Loom hold it", not "is any proxy set" — so a disable
    /// that *restored another app's* proxy still verifies, because Loom no longer
    /// holds it, which is the whole intent of the change.
    private static func verified(enabled: Bool, port: Int, attempts: Int = 10) -> Bool {
        for _ in 0..<attempts {
            if isPointing(port: port) == enabled { return true }
            usleep(100_000) // 0.1s
        }
        return false
    }

    // Loom deliberately does **not** back up and restore whoever held the proxy before
    // it. Restoring is only correct if that app is still running, and Loom has no way
    // to know: re-enabling a proxy pointed at an exited Charles would break every
    // request on the machine, which is strictly worse than leaving the setting off.
    // Turning Loom off therefore turns the proxy off, and the panel names the other
    // app while it *does* hold the setting so the human can go switch back themselves.

    private static func run(_ launchPath: String, _ arguments: [String]) -> (status: Int32, stderr: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        let errPipe = Pipe()
        process.standardError = errPipe
        process.standardOutput = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return (-1, error.localizedDescription)
        }
        let stderr = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return (process.terminationStatus, stderr)
    }

    /// Iterate enabled services (drop the header line and `*`-disabled ones) and
    /// point HTTP + HTTPS at the proxy.
    /// Point every service's proxy at Loom, then block QUIC so browser HTTP/3
    /// falls back to capturable TCP — both in one privileged call.
    ///
    /// The QUIC fragment runs LAST so the script's exit status is its exit
    /// status: pfctl needs root even for an admin user, and that status is the
    /// only way `apply` can tell "proxy set, QUIC blocked" from "proxy set, QUIC
    /// silently not blocked" and escalate.
    static func enableScript(host: String, port: Int) -> String {
        """
        #!/bin/sh
        /usr/sbin/networksetup -listallnetworkservices | tail -n +2 | grep -v '^\\*' | while IFS= read -r svc; do
          [ -z "$svc" ] && continue
          /usr/sbin/networksetup -setwebproxy "$svc" \(host) \(port)
          /usr/sbin/networksetup -setwebproxystate "$svc" on
          /usr/sbin/networksetup -setsecurewebproxy "$svc" \(host) \(port)
          /usr/sbin/networksetup -setsecurewebproxystate "$svc" on
        done
        \(QUICBlocker.enableFragment)
        """
    }

    /// Restore QUIC/firewall first, then turn the proxy off — the reverse order
    /// of enable, so we never leave QUIC blocked without the proxy running. The
    /// pf status is captured before the networksetup loop and re-emitted as the
    /// script's exit status, keeping the same contract as enable.
    ///
    /// With `restoreQUIC: false` (nothing was ever blocked) the script carries no
    /// pfctl at all, so an admin user's disable needs no root and stays silent.
    static func disableScript(restoreQUIC: Bool) -> String {
        guard restoreQUIC else {
            return """
            #!/bin/sh
            /usr/sbin/networksetup -listallnetworkservices | tail -n +2 | grep -v '^\\*' | while IFS= read -r svc; do
              [ -z "$svc" ] && continue
              /usr/sbin/networksetup -setwebproxystate "$svc" off
              /usr/sbin/networksetup -setsecurewebproxystate "$svc" off
            done
            """
        }
        return """
        #!/bin/sh
        \(QUICBlocker.disableFragment)
        loom_quic_status=$?
        /usr/sbin/networksetup -listallnetworkservices | tail -n +2 | grep -v '^\\*' | while IFS= read -r svc; do
          [ -z "$svc" ] && continue
          /usr/sbin/networksetup -setwebproxystate "$svc" off
          /usr/sbin/networksetup -setsecurewebproxystate "$svc" off
        done
        exit $loom_quic_status
        """
    }
}
