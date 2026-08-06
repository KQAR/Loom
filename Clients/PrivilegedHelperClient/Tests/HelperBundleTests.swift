import Foundation
import LoomHelperShared
import Testing

/// The plist and the code have to agree about three strings, and every disagreement
/// fails the same silent way: `SMAppService` reports `notFound`, or launchd never
/// starts anything, with nothing naming which half is wrong. Reading the checked-in
/// plist is cheap; debugging that state is not.
@Suite struct HelperBundleTests {
    private static let plistURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // PrivilegedHelperClient
        .deletingLastPathComponent()   // Clients
        .deletingLastPathComponent()   // repo root
        .appendingPathComponent("Helper/Daemon/com.loom.proxyhelper.plist")

    private func plist() throws -> [String: Any] {
        let data = try Data(contentsOf: Self.plistURL)
        let parsed = try PropertyListSerialization.propertyList(from: data, format: nil)
        return try #require(parsed as? [String: Any])
    }

    @Test func labelAndMachServiceMatchTheCode() throws {
        let plist = try plist()
        #expect(plist["Label"] as? String == HelperConstants.machServiceName)
        let services = try #require(plist["MachServices"] as? [String: Any])
        #expect(services[HelperConstants.machServiceName] as? Bool == true,
                "the daemon listens on this name; a plist that doesn't publish it never gets connected to")
    }

    /// `BundleProgram` is resolved relative to the app bundle, and the embed script
    /// puts the binary in `Contents/Library/HelperTools/` — where a privileged helper
    /// belongs, named after its label. Both halves are pinned by `PRODUCT_NAME`,
    /// because Xcode would otherwise emit `loom_helper`.
    @Test func bundleProgramPointsAtTheEmbeddedBinary() throws {
        #expect(try plist()["BundleProgram"] as? String == "Contents/Library/HelperTools/com.loom.proxyhelper")
    }

    /// Minimal on purpose: Label, MachServices, BundleProgram, nothing else. Every
    /// extra key is another thing launchd can refuse a spawn over, and this is the
    /// shape Apple documents for a privileged helper.
    @Test func thePlistCarriesNothingBeyondTheThreeRequiredKeys() throws {
        #expect(Set(try plist().keys) == ["Label", "MachServices", "BundleProgram"])
    }

    /// Demand-launched on purpose: a root process idling from boot for a toggle the
    /// human may never press is a worse default, and launchd starting it on the first
    /// connection is indistinguishable to the caller.
    @Test func theDaemonIsNotRunAtLoad() throws {
        #expect(try plist()["RunAtLoad"] == nil)
    }
}
