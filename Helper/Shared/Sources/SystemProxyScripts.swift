import Foundation

/// The shell Loom runs to move the system proxy, in **one** place.
///
/// Two callers execute this text: `SystemProxyApplier` (directly, or through an
/// osascript admin prompt) and the root helper (directly, already privileged).
/// They must run the same thing — a second copy is how the un-escalated path and
/// the privileged path drift into doing subtly different work, which is
/// undebuggable from either side. Same reasoning as `MITMPipeline` in ProxyCore.
public enum SystemProxyScripts {
    /// Point every enabled network service's HTTP + HTTPS proxy at `host:port`,
    /// then block QUIC so browser HTTP/3 falls back to capturable TCP.
    ///
    /// The QUIC fragment runs LAST so the script's exit status is its exit status:
    /// pfctl needs root even for an admin user, and that status is the only way an
    /// un-escalated caller can tell "proxy set, QUIC blocked" from "proxy set, QUIC
    /// silently not blocked" and escalate.
    public static func enable(host: String, port: Int) -> String {
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

    /// Restore QUIC/firewall first, then turn the proxy off — the reverse order of
    /// enable, so we never leave QUIC blocked without the proxy running. The pf
    /// status is captured before the networksetup loop and re-emitted as the
    /// script's exit status, keeping the same contract as enable.
    ///
    /// With `restoreQUIC: false` (nothing was ever blocked) the script carries no
    /// pfctl at all, so an admin user's disable needs no root and stays silent.
    public static func disable(restoreQUIC: Bool) -> String {
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

    /// The pf restore on its own — no networksetup, because this runs when Loom does
    /// *not* hold the proxy setting and must not touch it.
    public static var restoreQUICOnly: String {
        """
        #!/bin/sh
        \(QUICBlocker.disableFragment)
        """
    }
}
