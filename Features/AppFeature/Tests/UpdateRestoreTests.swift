import Testing
@testable import UpdaterClient

/// A found update outlives a relaunch, and stops replaying once it's installed.
@Suite struct UpdateRestoreTests {
    @Test func newerBuild_replaysAsAvailable() {
        let record = ["version": "0.0.37", "build": "36"]
        #expect(UpdaterCoordinator.restored(record, installedBuild: "30") == .available(version: "0.0.37"))
    }

    @Test func installedOrOlderBuild_isUnknown() {
        let record = ["version": "0.0.37", "build": "36"]
        #expect(UpdaterCoordinator.restored(record, installedBuild: "36") == .unknown)
        #expect(UpdaterCoordinator.restored(record, installedBuild: "40") == .unknown)
        #expect(UpdaterCoordinator.restored(nil, installedBuild: "30") == .unknown)
    }
}
