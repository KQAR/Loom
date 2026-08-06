import Foundation
import LoomHelperShared
import Testing

/// The requirement strings are the whole of the helper's access control, and both
/// ends build them from the same function — so what they say for a signed build and
/// for an ad-hoc one is worth pinning rather than assuming.
@Suite struct HelperRequirementTests {
    @Test func signedBuild_pinsBothIdentifierAndTeam() {
        let requirement = HelperRequirement.forClient(teamIdentifier: "ABCDE12345")
        #expect(requirement.contains("identifier \"com.loom.app\""))
        #expect(requirement.contains("certificate leaf[subject.OU] = \"ABCDE12345\""))
    }

    /// An ad-hoc build (Loom's CI archive) has no team, and the requirement must
    /// degrade to the identifier alone rather than to something unsatisfiable.
    /// `anchor apple generic` — the deleted 0.0.16 helper's hardcoded requirement —
    /// can never be met by an ad-hoc caller, which is what made the helper reject
    /// its own app on every shipped build.
    @Test func adHocBuild_dropsTheTeamClauseRatherThanFailingClosed() {
        for team in [nil, ""] {
            let requirement = HelperRequirement.forClient(teamIdentifier: team)
            #expect(requirement == "identifier \"com.loom.app\"")
            #expect(!requirement.contains("anchor apple generic"))
            #expect(!requirement.contains("subject.OU"))
        }
    }

    /// Each side checks the other. A daemon requirement that named the app would
    /// accept any process that could satisfy the app's own rule.
    @Test func theTwoDirectionsNameDifferentIdentifiers() {
        let client = HelperRequirement.forClient(teamIdentifier: "ABCDE12345")
        let daemon = HelperRequirement.forDaemon(teamIdentifier: "ABCDE12345")
        #expect(client.contains(HelperConstants.appBundleIdentifier))
        #expect(daemon.contains(HelperConstants.machServiceName))
        #expect(client != daemon)
    }

    /// The daemon's code-signing identifier has to equal the mach-service name, or
    /// `forDaemon` can never match. It is set by `PRODUCT_BUNDLE_IDENTIFIER` +
    /// `CREATE_INFOPLIST_SECTION_IN_BINARY` in Project.swift — a command-line tool
    /// otherwise signs as `loom-helper-<hash>`, and the mismatch surfaces only as
    /// "the helper is not reachable".
    @Test func serviceNameMatchesTheDaemonBundleIdentifier() {
        #expect(HelperConstants.machServiceName == "com.loom.proxyhelper")
        #expect(HelperConstants.daemonPlistName == "\(HelperConstants.machServiceName).plist")
    }
}
