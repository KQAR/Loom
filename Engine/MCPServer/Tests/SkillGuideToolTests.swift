import Foundation
import Testing
@testable import MCPServer

/// `get_skill_guide` is what the skill stub in an agent's skills directory points
/// at, so it must serve the guide's body, name its topics, and never read a path the
/// agent spelled.
@Suite struct SkillGuideToolTests {
    private func executor(_ dir: URL?) -> MCPToolExecutor {
        var executor = MCPToolExecutor(engine: StubEngine(), appVersion: "9.9", protocolVersion: "2025-06-18")
        executor.skillGuide = dir
        return executor
    }

    private func guideDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent("references"), withIntermediateDirectories: true)
        try "---\nname: loom\ndescription: x\n---\n\n# Guide\n\nabove\n---\nbelow\n"
            .write(to: dir.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        try "# Workflows\n".write(
            to: dir.appendingPathComponent("references/workflows.md"), atomically: true, encoding: .utf8)
        try "secret".write(to: dir.appendingPathComponent("other.md"), atomically: true, encoding: .utf8)
        return dir
    }

    @Test func servesTheBodyWithoutFrontmatter_andNamesTheTopics() async throws {
        let out = try await executor(guideDirectory()).call(name: "get_skill_guide", arguments: [:])
        #expect(out.hasPrefix("# Guide"))
        #expect(!out.contains("name: loom"))
        #expect(out.contains("above\n---\nbelow"))  // a rule in the body survives
        #expect(out.contains("Topics (the references/*.md above): workflows"))
    }

    @Test func servesATopic() async throws {
        let out = try await executor(guideDirectory())
            .call(name: "get_skill_guide", arguments: ["topic": "workflows"])
        #expect(out == "# Workflows\n")
    }

    @Test func aTopicIsALookupNotAPath() async throws {
        let ex = executor(try guideDirectory())
        for topic in ["../other", "../SKILL", "nope"] {
            await #expect(throws: (any Error).self) {
                try await ex.call(name: "get_skill_guide", arguments: ["topic": .string(topic)])
            }
        }
    }

    @Test func withoutABundledGuideItSaysSo() async {
        await #expect(throws: (any Error).self) {
            try await executor(nil).call(name: "get_skill_guide", arguments: [:])
        }
    }
}
