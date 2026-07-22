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
enum QUICBlocker {
    /// pf anchor name namespaced to Loom so restore can target only our rules.
    static let anchorName = "com.loom.quic"
    static let rulesPath = "/tmp/loom-quic.rules"
    static let mainConfPath = "/tmp/loom-pf.conf"
    static let disabledMarkerPath = "/tmp/loom-pf-was-disabled"

    /// The single pf rule: drop outbound UDP/443 (QUIC). `quick` makes it decisive
    /// the moment it's reached; the anchor is appended last so nothing overrides it.
    static let rule = "block drop out quick proto udp from any to any port = 443"

    /// Shell appended to the system-proxy **enable** script. Best-effort: pf
    /// failures must not fail proxy setup (TCP capture still works), so every
    /// pfctl call swallows errors. Runs as root inside the osascript admin call.
    static var enableFragment: String {
        """
        # --- Block QUIC (UDP/443) so browser HTTP/3 falls back to capturable TCP ---
        printf '%s\\n' '\(rule)' > \(rulesPath)
        /sbin/pfctl -s info 2>/dev/null | grep -q 'Status: Enabled' || touch \(disabledMarkerPath)
        cp /etc/pf.conf \(mainConfPath) 2>/dev/null || printf '' > \(mainConfPath)
        printf 'anchor "%s"\\nload anchor "%s" from "%s"\\n' '\(anchorName)' '\(anchorName)' '\(rulesPath)' >> \(mainConfPath)
        /sbin/pfctl -f \(mainConfPath) 2>/dev/null
        /sbin/pfctl -E 2>/dev/null
        """
    }

    /// Shell appended to the system-proxy **disable** script: flush our anchor,
    /// reload the pristine ruleset, and disable pf only if we were the ones who
    /// enabled it. Idempotent and safe to run even if QUIC was never blocked.
    static var disableFragment: String {
        """
        # --- Restore firewall / unblock QUIC ---
        /sbin/pfctl -a \(anchorName) -F rules 2>/dev/null
        /sbin/pfctl -f /etc/pf.conf 2>/dev/null
        if [ -f \(disabledMarkerPath) ]; then
          /sbin/pfctl -d 2>/dev/null
          rm -f \(disabledMarkerPath)
        fi
        rm -f \(rulesPath) \(mainConfPath)
        """
    }
}
