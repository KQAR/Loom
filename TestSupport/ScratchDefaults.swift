import Foundation
import Synchronization

/// Throwaway `UserDefaults` suites for tests, kept out of `~/Library/Preferences`.
///
/// A plain suite name lands in `~/Library/Preferences/<name>.plist`, and nothing a
/// test can do takes it back out: `removePersistentDomain(forName:)` empties the
/// domain and leaves the file, and deleting the file does not hold either — measured,
/// cfprefsd writes an empty `{}` plist back within seconds, with or without a
/// `synchronize()` first. Thousands had piled up.
///
/// So the suite is named by an **absolute path** under the temporary directory,
/// which CFPreferences honours as the plist's location. Whatever cfprefsd writes
/// back lands there, where the OS reaps it.
///
/// Hold one as a stored property of the test suite: Swift Testing makes a fresh
/// suite instance per test, so `deinit` clears what it handed out once the test is
/// over. Compiled into each test target that needs it (see `Project.swift`); it is
/// not a module, so there is no product for it to leak into.
final class ScratchDefaults: Sendable {
    private static let directory: String = {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("com.loom.tests", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.path
    }()

    private let names = Mutex<[String]>([])

    /// A new, empty suite.
    func make() -> UserDefaults {
        let name = "\(Self.directory)/\(UUID().uuidString)"
        names.withLock { $0.append(name) }
        return UserDefaults(suiteName: name)!
    }

    deinit {
        for name in names.withLock({ $0 }) {
            UserDefaults(suiteName: name)?.removePersistentDomain(forName: name)
            try? FileManager.default.removeItem(atPath: name + ".plist")
        }
    }
}
