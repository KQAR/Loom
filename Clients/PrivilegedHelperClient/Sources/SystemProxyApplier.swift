import Foundation
import LoomHelperShared
import Synchronization
import SystemConfiguration
import LoomSharedModels

/// Sets the macOS system HTTP+HTTPS proxy — through the privileged helper when one
/// is installed and approved, and without any helper when there isn't.
///
/// Strategy, in order: the **root helper** when it is installed, approved and
/// actually answering (`HelperInstall.ensureReady`) — then nothing is asked. Failing
/// that, run `networksetup` directly, which for admin users needs **no
/// authentication at all**; the result is verified against the effective proxy state
/// (`SCDynamicStoreCopyProxies`), and if it didn't stick — a non-admin account, or
/// the root-only pf work — the same script is retried through
/// `osascript … with administrator privileges`, which prompts once.
///
/// Every step falls through rather than failing: a helper that is missing, revoked
/// or broken costs a password prompt, never the feature.
///
/// Must run OFF the main thread — the fallback auth prompt is modal.
enum SystemProxyApplier {
    /// App-side record of whether the QUIC (pf) block is in place from a fully
    /// successful enable. pf state can't be read back without root, so this is
    /// what decides whether a disable has pf work to do at all — when it doesn't,
    /// the disable script carries no pfctl and an admin user's toggle-off stays
    /// prompt-free.
    static let quicBlockedKey = "com.loom.quicBlocked"

    /// Serializes whole applies. There are two independent writers — the panel
    /// toggle and the agent's `set_system_proxy` — and only the UI one is debounced
    /// (`systemProxyBusy`). Overlapping runs share the pf work files under
    /// `/var/root/com.loom`: one run's `rm -f` deletes the rules file the other is
    /// about to `load anchor` from, so its whole `pfctl -f` fails (silently, since
    /// pf stderr is swallowed). Interleaving an enable with a disable is worse — it
    /// can leave QUIC blocked on a machine whose proxy is off, the exact state the
    /// fragment ordering exists to prevent, because that ordering only holds within
    /// one call. Blocking is correct here: applies are human-speed and already off
    /// the main thread.
    /// Holds no state — it exists purely to serialize the critical section — so the
    /// `Mutex` wraps `Void` and the whole body runs inside `withLock`.
    private static let applyLock = Mutex(())

    static func apply(enabled: Bool, host: String, port: Int, defaults: UserDefaults = .standard) -> (Bool, String?) {
        applyLock.withLock { _ in
            let restoreQUIC = !enabled && defaults.bool(forKey: quicBlockedKey)

            // 0) The privileged helper, when the human has installed and approved
            //    one. This is the whole point of it: pf needs root, so without it
            //    every *enable* costs an admin prompt even on an admin account.
            //    Falls through to the paths below when it isn't installed, and also
            //    when it is installed but doesn't answer — a broken helper must not
            //    take the feature down with it, and the fallback still works, it
            //    just prompts.
            // `ensureReady`, not `state()`: "macOS has it registered" and "it answers"
            // are different facts, and the gap between them is a stale registration
            // left by an app update — which hangs an XPC call rather than failing it.
            if HelperInstall.ensureReady() {
                let outcome = HelperInstall.call { helper, reply in
                    helper.applySystemProxy(enabled: enabled, port: port, restoreQUIC: restoreQUIC, withReply: reply)
                }
                if outcome.ok, verified(enabled: enabled, port: port) {
                    defaults.set(enabled, forKey: quicBlockedKey)
                    return (true, nil)
                }
            }

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
    }

    /// Where this Mac's traffic currently goes. Reading needs no privileges. Used for
    /// the boot-time UI sync, post-apply verification, and the quit-time cleanup
    /// decision — one definition, so the human, the agent and the quit path can't
    /// disagree about whether Loom holds the proxy.
    static func routing(loomPort: Int) -> SystemProxyRouting {
        SystemProxyMonitor.snapshot().routing(loomPort: loomPort)
    }

    /// Clear a QUIC block that outlived the proxy it belonged to.
    ///
    /// A crash skips the quit-time cleanup, so `com.loom.quicBlocked` can still be
    /// set on the next launch while the system proxy no longer points at Loom
    /// (someone else took it, or the setting was cleared by hand). In that state the
    /// pf anchor keeps dropping *all* outbound UDP/443 machine-wide, and no UI path
    /// could remove it: the panel's toggle only ever runs the enable branch when the
    /// proxy is off, so the pf restore was unreachable. The only escape was a manual
    /// `sudo pfctl -f /etc/pf.conf`.
    ///
    /// Runs the pf restore alone (no networksetup — Loom doesn't hold the setting and
    /// must not touch it). `disableFragment` is idempotent, so a no-op costs one
    /// silent, un-escalated `sh -c`; only a genuinely present block escalates, and
    /// only then does the human see a prompt.
    ///
    /// Whether there is an orphaned block to clear. Separate from the effectful call
    /// below, and taking the routing as an input, so the decision is testable without
    /// a machine that happens to have a proxy set (and without ever reaching the
    /// escalation prompt).
    static func hasOrphanedQUICBlock(routing: SystemProxyRouting, defaults: UserDefaults = .standard) -> Bool {
        // Loom holds the proxy: the block belongs to this session, leave it be —
        // clearing it would silently stop capturing browser HTTP/3.
        defaults.bool(forKey: quicBlockedKey) && routing != .loom
    }

    /// - Returns: whether an orphaned block was found and cleared.
    @discardableResult
    static func restoreOrphanedQUICBlock(port: Int, defaults: UserDefaults = .standard) -> Bool {
        applyLock.withLock { _ in
            guard hasOrphanedQUICBlock(routing: routing(loomPort: port), defaults: defaults) else { return false }

            // Same order as `apply`: helper first when it's usable, so clearing a
            // crash leftover at launch doesn't greet the human with a password box.
            if HelperInstall.ensureReady() {
                if HelperInstall.call({ helper, reply in helper.restoreQUICBlock(withReply: reply) }).ok {
                    defaults.set(false, forKey: quicBlockedKey)
                    return true
                }
            }

            let script = SystemProxyScripts.restoreQUICOnly
            if run("/bin/sh", ["-c", script]).status == 0 {
                defaults.set(false, forKey: quicBlockedKey)
                return true
            }
            // Needs root. One prompt, explained by the caller's UI; if declined, the flag
            // stays set so the next launch (or toggle) tries again.
            let osascript = "do shell script \(appleScriptString(script)) with administrator privileges"
            if run("/usr/bin/osascript", ["-e", osascript]).status == 0 {
                defaults.set(false, forKey: quicBlockedKey)
                return true
            }
            return false
        }
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
    /// Note this checks "does Loom hold it", not "is any proxy set" — a disable
    /// verifies as soon as Loom no longer holds the setting, even if another app
    /// has already re-claimed it for itself. (Loom never restores a previous
    /// owner; see the note below.)
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

    /// The scripts themselves live in `SystemProxyScripts` (LoomHelperShared), because
    /// the root helper runs the very same text. Kept as thin forwarders so existing
    /// call sites and their tests keep naming this type — what must not exist is a
    /// *second definition* of what the toggle does.
    static func enableScript(host: String, port: Int) -> String {
        SystemProxyScripts.enable(host: host, port: port)
    }

    static func disableScript(restoreQUIC: Bool) -> String {
        SystemProxyScripts.disable(restoreQUIC: restoreQUIC)
    }
}
