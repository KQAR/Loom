import Testing
import Foundation
@testable import PrivilegedHelperClient

/// Pure-logic coverage for the QUIC-block firewall scripting. The live `pfctl`
/// path needs root and can't run in CI, so these assert the generated shell is
/// correct and reversible — the part that's easy to get subtly wrong.
@Suite struct QUICBlockerTests {
    @Test func enableFragment_dropsOutboundUDP443() {
        let s = QUICBlocker.enableFragment
        #expect(s.contains("proto udp"), "must target UDP")
        #expect(s.contains("port = 443"), "must target QUIC's port")
        #expect(s.contains("block drop out quick"), "must decisively drop outbound")
        #expect(s.contains("/sbin/pfctl -f"), "must load the ruleset")
        #expect(s.contains("/sbin/pfctl -E"), "must enable pf")
    }

    @Test func enableFragment_preservesUserPfConf() {
        let s = QUICBlocker.enableFragment
        // We copy the pristine /etc/pf.conf and append our anchor — never overwrite it.
        #expect(s.contains("cp /etc/pf.conf"), "must build on the user's existing config")
        // The anchor line is built at runtime via printf '%s' with the name as an arg.
        #expect(s.contains("anchor \"%s\""), "must emit an anchor reference")
        #expect(s.contains(QUICBlocker.anchorName), "must reference our namespaced anchor")
        #expect(!(s.contains("> /etc/pf.conf")), "must never clobber the system pf.conf")
    }

    @Test func enableFragment_failsClosedWithoutABaseline() {
        // `pfctl -f` replaces the whole loaded ruleset. If /etc/pf.conf can't be
        // copied, the old fallback loaded a config containing ONLY our anchor —
        // silently wiping the user's firewall. The baseline copy must gate the
        // entire pf section: no baseline, no QUIC block, and no synthesized conf.
        let s = QUICBlocker.enableFragment
        #expect(s.contains("if cp /etc/pf.conf \(QUICBlocker.mainConfPath)"),
                "the baseline copy must be the gate, not a best-effort step")
        #expect(!s.contains("|| printf '' >"),
                "must never synthesize an empty baseline to load")
        // Both pfctl mutations sit inside the guarded branch.
        for line in ["/sbin/pfctl -f \(QUICBlocker.mainConfPath)", "/sbin/pfctl -E"] {
            let guarded = s.range(of: "if cp /etc/pf.conf").map { s[$0.upperBound...].contains(line) }
            #expect(guarded == true, "\(line) must run only after the baseline copy succeeded")
        }
    }

    @Test func enableFragment_recordsPriorPfState() {
        // So restore can put pf back to disabled if that's how it started.
        let s = QUICBlocker.enableFragment
        #expect(s.contains("Status: Enabled"))
        #expect(s.contains("touch \(QUICBlocker.disabledMarkerPath)"))
    }

    @Test func disableFragment_isReversibleAndScoped() {
        let s = QUICBlocker.disableFragment
        // Flush only our anchor, then reload the pristine ruleset.
        #expect(s.contains("-a \(QUICBlocker.anchorName) -F rules"), "flush only our rules")
        #expect(s.contains("/sbin/pfctl -f /etc/pf.conf"), "restore the pristine ruleset")
        // Only disable pf if we were the ones who enabled it.
        #expect(s.contains("if [ -f \(QUICBlocker.disabledMarkerPath) ]"))
        #expect(s.contains("/sbin/pfctl -d"))
        #expect(s.contains("rm -f \(QUICBlocker.disabledMarkerPath)"))
    }

    @Test func anchorNamespacedToLoom() {
        // Namespacing keeps restore from touching anyone else's pf anchors.
        #expect(QUICBlocker.anchorName.hasPrefix("com.loom"))
    }

    @Test func fragments_reportPfOutcomeInTheirExitStatus() {
        // Every pfctl needs root (/dev/pf is root-only), and stderr is swallowed —
        // so the exit status is the ONE channel telling `apply` that the silent
        // un-escalated run set the proxy without touching pf. Both fragments wrap
        // in a function whose return value is that signal; the fail-closed branch
        // must return non-zero rather than fall through as success.
        let enable = QUICBlocker.enableFragment
        #expect(enable.contains("loom_quic_enable()"))
        #expect(enable.hasSuffix("loom_quic_enable"), "the fragment must end by invoking the function so its status propagates")
        #expect(enable.contains("return 1"), "fail-closed must surface in the exit status, not read as success")
        #expect(enable.contains("/sbin/pfctl -f \(QUICBlocker.mainConfPath) 2>/dev/null && /sbin/pfctl -E"),
                "load and enable must be chained so a failed load can't report success")

        let disable = QUICBlocker.disableFragment
        #expect(disable.contains("loom_quic_disable()"))
        #expect(disable.hasSuffix("loom_quic_disable"))
        #expect(disable.contains("return $loom_pf_restored"),
                "the restore outcome must survive the best-effort cleanup steps")
    }

    @Test func workingFilesAreRootOnly_notWorldWritableTmp() {
        // Regression: predictable /tmp paths let a non-root process pre-plant a
        // symlink that redirected our root-run writes. Work files must live under
        // /var/root, which non-root can't write to.
        for path in [QUICBlocker.rulesPath, QUICBlocker.mainConfPath, QUICBlocker.disabledMarkerPath] {
            #expect(path.hasPrefix("/var/root/"), "\(path) must be under /var/root")
            #expect(!(path.hasPrefix("/tmp/")), "\(path) must not be in world-writable /tmp")
        }
        // And we defend in depth: drop any pre-existing file before writing.
        let s = QUICBlocker.enableFragment
        #expect(s.contains("set -C"), "noclobber guards against a planted symlink")
        #expect(s.contains("rm -f \(QUICBlocker.rulesPath)"))
    }
}

/// The scripts `SystemProxyApplier` feeds to sh — the exit-status contract that
/// lets the silent (un-escalated) run admit the root-only pf work didn't happen,
/// and the ordering invariant that QUIC is never left blocked with the proxy off.
@Suite struct SystemProxyScriptTests {
    @Test func enableScript_endsWithTheQUICFragment_soExitStatusReportsPf() {
        let s = SystemProxyApplier.enableScript(host: "127.0.0.1", port: 9090)
        #expect(s.contains("networksetup -setwebproxy"))
        #expect(s.hasSuffix("loom_quic_enable"),
                "the pf outcome must be the script's exit status — it's how apply() learns the silent admin run didn't block QUIC")
    }

    @Test func disableScript_withRestore_restoresPfFirst_butReportsItsStatusLast() {
        let s = SystemProxyApplier.disableScript(restoreQUIC: true)
        let pf = s.range(of: "loom_quic_disable")
        let proxy = s.range(of: "networksetup -setwebproxystate")
        #expect(pf != nil && proxy != nil && pf!.lowerBound < proxy!.lowerBound,
                "pf restores before the proxy drops — never leave QUIC blocked on a machine whose proxy is off")
        #expect(s.hasSuffix("exit $loom_quic_status"),
                "the pf outcome must survive the networksetup loop as the script's exit status")
    }

    @Test func disableScript_withNothingToRestore_carriesNoPfctl() {
        // No pf work → nothing needs root → the direct run exits 0 and the admin
        // user's toggle-off stays prompt-free, exactly as before QUIC tracking.
        let s = SystemProxyApplier.disableScript(restoreQUIC: false)
        #expect(!s.contains("pfctl"))
        #expect(s.contains("networksetup -setwebproxystate"))
    }
}
