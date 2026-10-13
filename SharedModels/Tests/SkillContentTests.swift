import Foundation
import Testing

/// Guards on the agent skill's prose (`skills/loom/`), which ships inside the app
/// bundle and is what an agent reads before any tool description.
///
/// Reads the repo through `#filePath`, so it fails if the files move.
@Suite struct SkillContentTests {
    private static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // Tests
        .deletingLastPathComponent()  // SharedModels
        .deletingLastPathComponent()  // repo root

    private func read(_ relativePath: String) throws -> String {
        try String(contentsOf: Self.repoRoot.appendingPathComponent(relativePath), encoding: .utf8)
    }

    /// The skill's rule-shape list is what an agent reads first. Omitting
    /// `drop_from_capture` there is how "the client made no requests" gets reported
    /// while a noise-filter rule is eating every match.
    @Test func theSkillNamesTheCaptureDropAction() throws {
        #expect((try read("skills/loom/SKILL.md")).contains("drop_from_capture"))
    }

    /// The upstream leg matches the client's protocol; claiming it is always
    /// HTTP/1.1 makes a normal h2/h2 pair look like a bug, or a real fault look
    /// like a known non-bug.
    @Test func filingABugDoesNotClaimTheUpstreamLegIsAlwaysHTTP11() throws {
        #expect(!(try read("skills/loom/references/filing-a-bug.md")).contains("always HTTP/1.1"))
    }
}
