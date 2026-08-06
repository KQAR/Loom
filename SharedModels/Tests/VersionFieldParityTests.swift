import Foundation
import Testing

/// The app's version is written down in four places, and nothing in the build ties
/// them together: `Project.swift`'s `CFBundleShortVersionString` plus the three plugin
/// manifests (`.claude-plugin/plugin.json`, `.cursor-plugin/plugin.json`, and the
/// nested one in `.cursor-plugin/marketplace.json` — `.claude-plugin/marketplace.json`
/// has none).
///
/// They have drifted before: the manifests sat at 0.0.14 through the whole of 0.0.15,
/// because `release.yml` only tags and builds. So the drift is checked here instead of
/// trusted to a release checklist — and the loom skill deliberately adds no fifth copy,
/// which the last test in this suite is what keeps true.
///
/// Reads the repo through `#filePath`, so it fails if the files move; that is the
/// intended behaviour, since a moved manifest is exactly a manifest that stopped
/// being maintained.
@Suite struct VersionFieldParityTests {
    private static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // Tests
        .deletingLastPathComponent()  // SharedModels
        .deletingLastPathComponent()  // repo root

    private func read(_ relativePath: String) throws -> String {
        try String(contentsOf: Self.repoRoot.appendingPathComponent(relativePath), encoding: .utf8)
    }

    /// The app version, from the one place that decides it.
    private func appVersion() throws -> String {
        let manifest = try read("Project.swift")
        let pattern = #""CFBundleShortVersionString"\s*:\s*"([0-9]+\.[0-9]+\.[0-9]+)""#
        let match = try #require(
            manifest.range(of: pattern, options: .regularExpression),
            "Project.swift no longer declares CFBundleShortVersionString in the expected shape"
        )
        let declaration = String(manifest[match])
        let version = try #require(
            declaration.range(of: #"[0-9]+\.[0-9]+\.[0-9]+"#, options: .regularExpression)
        )
        return String(declaration[version])
    }

    @Test func everyPluginManifestCarriesTheAppVersion() throws {
        let expected = try appVersion()
        for path in [
            ".claude-plugin/plugin.json",
            ".cursor-plugin/plugin.json",
            ".cursor-plugin/marketplace.json",
        ] {
            let contents = try read(path)
            #expect(
                contents.contains("\"version\": \"\(expected)\""),
                "\(path) does not carry version \(expected) — bump it with the app version, in the same change"
            )
        }
    }

    /// The skill must **not** carry a version of its own.
    ///
    /// It tells the agent to compare `get_version.appVersion` against the plugin's own
    /// manifest, read at runtime — so there is one number, in the manifests, and the
    /// skew check reads it rather than restating it. A copied number here is the worst
    /// of the five: stale, it makes the agent report a mismatch that isn't there, or
    /// miss one that is. Cheap to add by accident while editing prose, hence the guard.
    @Test func theSkillDoesNotHardcodeAVersion() throws {
        let skill = try read("skills/loom/SKILL.md")
        let versions = skill.ranges(of: try Regex(#"\b[0-9]+\.[0-9]+\.[0-9]+\b"#))
        #expect(
            versions.isEmpty,
            "skills/loom/SKILL.md names a version literal; have the agent read the plugin manifest instead"
        )
        // …and it still has to tell the agent *where* to read it, or the check silently
        // stops happening.
        #expect(skill.contains(".claude-plugin/plugin.json"))
        #expect(skill.contains("appVersion"))
    }

    /// `.claude-plugin/marketplace.json` deliberately has no version field. Pinned so
    /// that "there are three, not four" stays a fact rather than an assumption.
    @Test func theClaudeMarketplaceManifestHasNoVersionOfItsOwn() throws {
        #expect(!(try read(".claude-plugin/marketplace.json")).contains("\"version\""))
    }
}
