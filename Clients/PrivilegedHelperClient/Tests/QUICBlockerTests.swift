import XCTest
@testable import PrivilegedHelperClient

/// Pure-logic coverage for the QUIC-block firewall scripting. The live `pfctl`
/// path needs root and can't run in CI, so these assert the generated shell is
/// correct and reversible — the part that's easy to get subtly wrong.
final class QUICBlockerTests: XCTestCase {
    func test_enableFragment_dropsOutboundUDP443() {
        let s = QUICBlocker.enableFragment
        XCTAssertTrue(s.contains("proto udp"), "must target UDP")
        XCTAssertTrue(s.contains("port = 443"), "must target QUIC's port")
        XCTAssertTrue(s.contains("block drop out quick"), "must decisively drop outbound")
        XCTAssertTrue(s.contains("/sbin/pfctl -f"), "must load the ruleset")
        XCTAssertTrue(s.contains("/sbin/pfctl -E"), "must enable pf")
    }

    func test_enableFragment_preservesUserPfConf() {
        let s = QUICBlocker.enableFragment
        // We copy the pristine /etc/pf.conf and append our anchor — never overwrite it.
        XCTAssertTrue(s.contains("cp /etc/pf.conf"), "must build on the user's existing config")
        // The anchor line is built at runtime via printf '%s' with the name as an arg.
        XCTAssertTrue(s.contains("anchor \"%s\""), "must emit an anchor reference")
        XCTAssertTrue(s.contains(QUICBlocker.anchorName), "must reference our namespaced anchor")
        XCTAssertFalse(s.contains("> /etc/pf.conf"), "must never clobber the system pf.conf")
    }

    func test_enableFragment_recordsPriorPfState() {
        // So restore can put pf back to disabled if that's how it started.
        let s = QUICBlocker.enableFragment
        XCTAssertTrue(s.contains("Status: Enabled"))
        XCTAssertTrue(s.contains("touch \(QUICBlocker.disabledMarkerPath)"))
    }

    func test_disableFragment_isReversibleAndScoped() {
        let s = QUICBlocker.disableFragment
        // Flush only our anchor, then reload the pristine ruleset.
        XCTAssertTrue(s.contains("-a \(QUICBlocker.anchorName) -F rules"), "flush only our rules")
        XCTAssertTrue(s.contains("/sbin/pfctl -f /etc/pf.conf"), "restore the pristine ruleset")
        // Only disable pf if we were the ones who enabled it.
        XCTAssertTrue(s.contains("if [ -f \(QUICBlocker.disabledMarkerPath) ]"))
        XCTAssertTrue(s.contains("/sbin/pfctl -d"))
        XCTAssertTrue(s.contains("rm -f \(QUICBlocker.disabledMarkerPath)"))
    }

    func test_anchorNamespacedToLoom() {
        // Namespacing keeps restore from touching anyone else's pf anchors.
        XCTAssertTrue(QUICBlocker.anchorName.hasPrefix("com.loom"))
    }

    func test_workingFilesAreRootOnly_notWorldWritableTmp() {
        // Regression: predictable /tmp paths let a non-root process pre-plant a
        // symlink that redirected our root-run writes. Work files must live under
        // /var/root, which non-root can't write to.
        for path in [QUICBlocker.rulesPath, QUICBlocker.mainConfPath, QUICBlocker.disabledMarkerPath] {
            XCTAssertTrue(path.hasPrefix("/var/root/"), "\(path) must be under /var/root")
            XCTAssertFalse(path.hasPrefix("/tmp/"), "\(path) must not be in world-writable /tmp")
        }
        // And we defend in depth: drop any pre-existing file before writing.
        let s = QUICBlocker.enableFragment
        XCTAssertTrue(s.contains("set -C"), "noclobber guards against a planted symlink")
        XCTAssertTrue(s.contains("rm -f \(QUICBlocker.rulesPath)"))
    }
}
