import Foundation

/// Firewall (pf) fragments that block outbound QUIC so browsers fall back to
/// TCP (HTTP/2 / HTTP/1.1) — which a system HTTP proxy can actually intercept.
///
/// Why this exists: a macOS system HTTP proxy only carries **TCP** CONNECT
/// tunnels. Chrome/Safari default to **HTTP/3 over QUIC (UDP 443)**, which has no
/// proxy path, so browser page loads bypass Loom entirely and are never captured.
/// Dropping outbound UDP 443 forces the QUIC handshake to fail fast; the browser
/// retries over TCP through the proxy, and Loom captures it. This is exactly the
/// "Block QUIC" behavior in Charles / Proxyman.
///
/// The fragments are composed into the same privileged `osascript` call that sets
/// the system proxy, so enabling capture is one authorization, and quit/disable
/// restores the firewall in lockstep with the proxy.
///
/// Safety: we never overwrite the user's pf config. Enable copies `/etc/pf.conf`,
/// appends our anchor, and loads the copy; a marker file records whether pf was
/// already enabled so restore can put it back exactly. Restore reloads the
/// pristine `/etc/pf.conf`, dropping our rules.
///
/// The working files live under `/var/root` (root's home, `drwxr-xr-x root:wheel`)
/// — a non-root process can't create files there, so it can't pre-plant a symlink
/// that redirects our root-run `>`/`cp` at `/etc/pf.conf` or plant a fake ruleset
/// for `pfctl -f` to load. Predictable `/tmp` paths (world-writable) previously
/// made both attacks trivial. `rm -f` + `set -C` (noclobber) add defense in depth.
public enum QUICBlocker {
    /// pf anchor name namespaced to Loom so restore can target only our rules.
    public static let anchorName = "com.loom.quic"
    public static let workDir = "/var/root/com.loom"
    public static let rulesPath = "\(workDir)/quic.rules"
    public static let mainConfPath = "\(workDir)/pf.conf"
    public static let disabledMarkerPath = "\(workDir)/pf-was-disabled"

    /// The single pf rule: drop outbound UDP/443 (QUIC). `quick` makes it decisive
    /// the moment it's reached; the anchor is appended last so nothing overrides it.
    public static let rule = "block drop out quick proto udp from any to any port = 443"

    /// Shell appended to the system-proxy **enable** script. pf stderr is
    /// swallowed (the noise is useless), but the fragment's **exit status is the
    /// contract**: it runs last in the enable script, and every pfctl needs root
    /// (`/dev/pf` is root-only) — so a non-zero script status is how the caller
    /// learns the un-escalated "silent admin" run set the proxy *without* blocking
    /// QUIC, and that it must retry through the admin prompt. Swallowing that too
    /// is how admin users ran for months with HTTP/3 never actually blocked.
    public static var enableFragment: String {
        """
        # --- Block QUIC (UDP/443) so browser HTTP/3 falls back to capturable TCP ---
        loom_quic_enable() {
          umask 077
          /bin/mkdir -p \(workDir) || return 1
          set -C                              # noclobber: never follow a planted symlink
          rm -f \(rulesPath) \(mainConfPath)  # drop any pre-existing file/symlink first
          printf '%s\\n' '\(rule)' > \(rulesPath) || return 1
          # Fail closed on a missing baseline: `pfctl -f` replaces the WHOLE loaded
          # ruleset, so loading a copy that is only our anchor would wipe the user's
          # firewall. If /etc/pf.conf can't be read, skip blocking QUIC entirely —
          # an unblocked QUIC is a capture gap; an emptied ruleset is a security hole.
          if cp /etc/pf.conf \(mainConfPath) 2>/dev/null; then
            printf 'anchor "%s"\\nload anchor "%s" from "%s"\\n' '\(anchorName)' '\(anchorName)' '\(rulesPath)' >> \(mainConfPath)
            /sbin/pfctl -s info 2>/dev/null | grep -q 'Status: Enabled' || touch \(disabledMarkerPath)
            /sbin/pfctl -f \(mainConfPath) 2>/dev/null && /sbin/pfctl -E 2>/dev/null
          else
            rm -f \(rulesPath) \(mainConfPath)
            return 1
          fi
        }
        loom_quic_enable
        """
    }

    /// Shell appended to the system-proxy **disable** script: flush our anchor,
    /// reload the pristine ruleset, and disable pf only if we were the ones who
    /// enabled it. Idempotent and safe to run even if QUIC was never blocked.
    /// Same exit-status contract as the enable fragment: the function's status
    /// reports whether the pf restore itself succeeded (the marker/cleanup steps
    /// are best-effort), so an un-escalated run can't silently leave UDP/443
    /// blocked on a machine whose proxy is already off.
    public static var disableFragment: String {
        """
        # --- Restore firewall / unblock QUIC ---
        loom_quic_disable() {
          /sbin/pfctl -a \(anchorName) -F rules 2>/dev/null && /sbin/pfctl -f /etc/pf.conf 2>/dev/null
          loom_pf_restored=$?
          if [ -f \(disabledMarkerPath) ]; then
            /sbin/pfctl -d 2>/dev/null
            rm -f \(disabledMarkerPath)
          fi
          rm -f \(rulesPath) \(mainConfPath)
          return $loom_pf_restored
        }
        loom_quic_disable
        """
    }
}
