import Foundation
import SystemConfiguration
import SharedModels

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

        // Write the shell script to a user-only temp file.
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("loom-sysproxy-\(UUID().uuidString).sh")
        do {
            try script.write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        } catch {
            return (false, "could not stage proxy script: \(error.localizedDescription)")
        }
        defer { try? FileManager.default.removeItem(at: url) }

        // 1) Direct, silent path (works for admin users).
        _ = run("/bin/sh", [url.path])
        if verified(enabled: enabled, host: host, port: port) { return (true, nil) }

        // 2) Fallback: same script under one admin prompt.
        let osascript = "do shell script \"/bin/sh \(url.path)\" with administrator privileges"
        let (status, stderr) = run("/usr/bin/osascript", ["-e", osascript])
        if status == 0, verified(enabled: enabled, host: host, port: port) { return (true, nil) }
        if stderr.contains("User canceled") || stderr.contains("-128") {
            return (false, "Authorization cancelled.")
        }
        return (false, stderr.isEmpty ? "networksetup failed" : stderr.trimmingCharacters(in: .whitespacesAndNewlines))
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
