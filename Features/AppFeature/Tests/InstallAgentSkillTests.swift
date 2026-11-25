import Foundation
import Testing

/// `install-agent.sh skill setup|status|remove`, run against a throwaway `HOME` laid
/// out as the old symlink installer left it. Only a file carrying the `loom-stub`
/// marker — or an old link into a Loom bundle — is Loom's to touch.
@Suite struct InstallAgentSkillTests {
    private static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()

    private let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    private var home: URL { root.appendingPathComponent("home") }
    private var resources: URL { root.appendingPathComponent("Loom.app/Contents/Resources") }
    private let fm = FileManager.default

    init() throws {
        try fm.createDirectory(at: resources.appendingPathComponent("skills/loom"), withIntermediateDirectories: true)
        try fm.copyItem(at: Self.repoRoot.appendingPathComponent("skills/loom/SKILL.md"),
                        to: resources.appendingPathComponent("skills/loom/SKILL.md"))
        try fm.copyItem(at: Self.repoRoot.appendingPathComponent("App/Agent/install-agent.sh"),
                        to: resources.appendingPathComponent("install-agent.sh"))
        for dir in [".claude/skills", ".cursor/skills"] {
            try fm.createDirectory(at: home.appendingPathComponent(dir), withIntermediateDirectories: true)
        }
    }

    @discardableResult
    private func run(_ args: String...) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [resources.appendingPathComponent("install-agent.sh").path] + args
        process.environment = ["HOME": home.path, "PATH": "/usr/bin:/bin"]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = out
        try process.run()
        process.waitUntilExit()
        let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        #expect(process.terminationStatus == 0, "\(text)")
        return text
    }

    private func path(_ relative: String) -> String { home.appendingPathComponent(relative).path }

    @Test func migratesOldLinks_reportsState_andRemovesOnlyItsOwn() throws {
        // A dangling link (Loom moved) and Cursor's old link.
        try fm.createSymbolicLink(atPath: path(".claude/skills/loom"),
                                  withDestinationPath: "/Gone/Loom.app/Contents/Resources/skills/loom")
        try fm.createSymbolicLink(atPath: path(".cursor/skills/loom"),
                                  withDestinationPath: "/Applications/Loom.app/Contents/Resources/skills/loom")
        #expect(try run("skill", "status").contains("legacy"))

        try run("skill", "setup")
        let stub = try String(contentsOfFile: path(".claude/skills/loom/SKILL.md"), encoding: .utf8)
        #expect(stub.contains("name: loom"))
        #expect(stub.contains("loom-stub: \"1\""))
        #expect(stub.contains("get_skill_guide"))
        #expect(try String(contentsOfFile: path(".agents/skills/loom/SKILL.md"), encoding: .utf8) == stub)
        #expect((try? fm.destinationOfSymbolicLink(atPath: path(".cursor/skills/loom"))) == nil)
        #expect(!(try run("skill", "status").contains("legacy")))

        // An older Loom's stub is refreshed at launch; a foreign file never is.
        try stub.replacingOccurrences(of: "get_skill_guide", with: "old")
            .write(toFile: path(".agents/skills/loom/SKILL.md"), atomically: true, encoding: .utf8)
        #expect(try run("skill", "status").contains("outdated"))
        #expect(try run("skill", "setup", "--installed-only").contains("refreshed   ~/.agents/skills/loom"))
        try "mine".write(toFile: path(".claude/skills/loom/SKILL.md"), atomically: true, encoding: .utf8)
        #expect(try run("skill", "setup").contains("skipped     ~/.claude/skills/loom"))

        try run("skill", "remove")
        #expect(try String(contentsOfFile: path(".claude/skills/loom/SKILL.md"), encoding: .utf8) == "mine")
        #expect(!fm.fileExists(atPath: path(".agents/skills/loom")))
    }

    @Test func installedOnlyInstallsNothingNew() throws {
        #expect(try run("skill", "setup", "--installed-only").isEmpty)
        #expect(!fm.fileExists(atPath: path(".claude/skills/loom")))
    }
}
