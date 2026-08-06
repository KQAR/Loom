import Testing
import Foundation
import LoomHelperShared
@testable import PrivilegedHelperClient

/// Parses the pf config the enable script would build through the real
/// `pfctl -nf` (parse-only, needs no root) — so "the generated ruleset is valid
/// pf syntax" is a test, not a claim. The live load still needs root and one
/// real toggle to verify end-to-end; this pins the half that CI *can* check:
/// the rule grammar and the anchor/load-anchor lines against pf's own parser.
@Suite struct PfctlSyntaxValidationTests {
    @Test func generatedRulesetParsesUnderPfctl() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("loom-pfctl-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        // The anchor rules file, exactly as the fragment writes it.
        let rules = dir.appendingPathComponent("quic.rules")
        try (QUICBlocker.rule + "\n").write(to: rules, atomically: true, encoding: .utf8)

        // The main conf, exactly as the fragment builds it: the user's baseline
        // (readable without root) plus our anchor + load-anchor lines. Only the
        // work-dir path differs — /var/root isn't writable here.
        let baseline = (try? String(contentsOfFile: "/etc/pf.conf", encoding: .utf8)) ?? ""
        let conf = dir.appendingPathComponent("pf.conf")
        let anchorLines = "anchor \"\(QUICBlocker.anchorName)\"\nload anchor \"\(QUICBlocker.anchorName)\" from \"\(rules.path)\"\n"
        try (baseline + anchorLines).write(to: conf, atomically: true, encoding: .utf8)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/sbin/pfctl")
        process.arguments = ["-nf", conf.path]
        let errPipe = Pipe()
        process.standardError = errPipe
        process.standardOutput = Pipe()
        try process.run()
        process.waitUntilExit()
        let stderr = String(
            data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8
        ) ?? ""

        #expect(process.terminationStatus == 0,
                "pfctl rejected the generated ruleset: \(stderr)")
    }
}
