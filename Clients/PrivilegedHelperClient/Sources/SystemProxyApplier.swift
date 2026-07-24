import Foundation
import SystemConfiguration
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
    static func apply(enabled: Bool, host: String, port: Int) -> (Bool, String?) {
        let script = enabled ? enableScript(host: host, port: port) : disableScript()

        // 1) Direct, silent path (works for admin users): feed the script to sh on
        //    stdin-equivalent `-c`, never touching disk.
        _ = run("/bin/sh", ["-c", script])
        if verified(enabled: enabled, host: host, port: port) { return (true, nil) }

        // 2) Fallback: the SAME script inlined into one admin prompt. Inlining the
        //    text (rather than writing a script file and running it as root) closes
        //    a privilege-escalation TOCTOU — a same-uid process could otherwise
        //    swap the staged file between our write and the privileged execution,
        //    turning Loom's authorization dialog into arbitrary root code.
        let osascript = "do shell script \(appleScriptString(script)) with administrator privileges"
        let (status, stderr) = run("/usr/bin/osascript", ["-e", osascript])
        if status == 0, verified(enabled: enabled, host: host, port: port) { return (true, nil) }
        if stderr.contains("User canceled") || stderr.contains("-128") {
            return (false, "Authorization cancelled.")
        }
        return (false, stderr.isEmpty ? "networksetup failed" : stderr.trimmingCharacters(in: .whitespacesAndNewlines))
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

    /// Whether the *effective* system proxy currently routes HTTP+HTTPS through
    /// `host:port`. Reading needs no privileges. Used for the boot-time UI sync,
    /// post-apply verification, and the quit-time cleanup decision.
    static func isPointing(at host: String, port: Int) -> Bool {
        guard let cf = SCDynamicStoreCopyProxies(nil) as? [String: Any] else { return false }
        return SystemProxyParsing.effectiveProxiesPoint(at: host, port: port, in: cf)
    }

    // MARK: - Internals

    /// The dynamic store lags a written config by a beat; poll briefly.
    private static func verified(enabled: Bool, host: String, port: Int, attempts: Int = 10) -> Bool {
        for _ in 0..<attempts {
            let pointing = isPointing(at: host, port: port)
            if pointing == enabled { return true }
            usleep(100_000) // 0.1s
        }
        return false
    }

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
    private static func enableScript(host: String, port: Int) -> String {
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
    /// of enable, so we never leave QUIC blocked without the proxy running.
    private static func disableScript() -> String {
        """
        #!/bin/sh
        \(QUICBlocker.disableFragment)
        /usr/sbin/networksetup -listallnetworkservices | tail -n +2 | grep -v '^\\*' | while IFS= read -r svc; do
          [ -z "$svc" ] && continue
          /usr/sbin/networksetup -setwebproxystate "$svc" off
          /usr/sbin/networksetup -setsecurewebproxystate "$svc" off
        done
        """
    }
}
