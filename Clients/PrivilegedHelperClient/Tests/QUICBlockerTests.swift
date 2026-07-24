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
