import Foundation
import Sparkle

/// Owns Sparkle's updater for the app's lifetime and adapts its delegate
/// callbacks into an `AsyncStream` the TCA layer consumes. Kept out of the
/// public API of `UpdaterClient` so Sparkle stays an implementation detail.
///
/// We drive the cadence ourselves (`SUEnableAutomaticChecks` is off in the app's
/// Info.plist): `checkInBackgroundIfDue` runs a *silent* probe at most once a day
/// — no UI, it only flips the panel button style — while `checkForUpdates`
/// performs a user-initiated check with Sparkle's standard install UI.
@MainActor
final class UpdaterCoordinator: NSObject {
    static let shared = UpdaterCoordinator()

    /// At most one silent background probe per this interval (≈ once a day).
    ///
    /// `nonisolated` because the delegate callback that stamps the timestamp is
    /// nonisolated (Sparkle calls it on the main queue, but its protocol doesn't say
    /// so) — and a constant needs no isolation to be read safely.
    nonisolated private static let probeInterval: TimeInterval = 24 * 60 * 60
    nonisolated private static let lastProbeKey = "com.loom.lastUpdateCheck"
    /// The last update a probe found, `{version, build}`. Persisted because the
    /// probe is gated to once a day and `current` lives in memory: without it, one
    /// relaunch inside that day put the footer back to a plain version number and
    /// kept it there — a machine sat on 0.0.31 through six releases that way.
    nonisolated static let foundUpdateKey = "com.loom.foundUpdate"

    private var controller: SPUStandardUpdaterController!
    private var continuations: [UUID: AsyncStream<UpdateAvailability>.Continuation] = [:]
    /// Last availability we learned, replayed to every new subscriber.
    private(set) var current: UpdateAvailability

    override init() {
        current = Self.restored(
            UserDefaults.standard.dictionary(forKey: Self.foundUpdateKey) as? [String: String],
            installedBuild: Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"
        )
        super.init()
        // startingUpdater: true — Sparkle begins its lifecycle immediately so the
        // feed/permission state is ready. It won't pop UI on its own because we
        // keep automatic checks off and only probe silently.
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: self,
            userDriverDelegate: nil
        )
    }

    private var updater: SPUUpdater { controller.updater }

    var canCheckForUpdates: Bool { updater.canCheckForUpdates }

    /// A fresh subscription that first replays the last known availability, then
    /// receives every subsequent change. Supports multiple subscribers.
    func availabilityStream() -> AsyncStream<UpdateAvailability> {
        AsyncStream { continuation in
            let id = UUID()
            continuations[id] = continuation
            continuation.yield(current)
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor in self?.continuations[id] = nil }
            }
        }
    }

    /// User-initiated check — shows Sparkle's standard update UI (download +
    /// install), independent of what the last silent probe found.
    func checkForUpdates() {
        updater.checkForUpdates()
    }

    /// Silent probe, at most once per `probeInterval`. Never shows UI; the
    /// delegate callbacks below fold the result into `availabilityStream`.
    func checkInBackgroundIfDue() {
        if let last = UserDefaults.standard.object(forKey: Self.lastProbeKey) as? Date,
           Date().timeIntervalSince(last) < Self.probeInterval {
            return
        }
        updater.checkForUpdateInformation()
    }

    /// A persisted find replays as `.available` only while it is newer than what is
    /// installed — so updating is what retires it, with nothing to clean up. Compared
    /// on the build number, which is the field Sparkle itself compares.
    nonisolated static func restored(_ record: [String: String]?, installedBuild: String) -> UpdateAvailability {
        guard let version = record?["version"], let build = record?["build"],
              SUStandardVersionComparator().compareVersion(build, toVersion: installedBuild) == .orderedDescending
        else { return .unknown }
        return .available(version: version)
    }

    private func broadcast(_ value: UpdateAvailability) {
        current = value
        for continuation in continuations.values { continuation.yield(value) }
    }
}

extension UpdaterCoordinator: SPUUpdaterDelegate {
    // Sparkle invokes these on the main queue; hop to the actor explicitly and
    // carry only Sendable values across so it holds under strict concurrency too.
    nonisolated func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        let version = item.displayVersionString
        let build = item.versionString
        Task { @MainActor [weak self] in
            UserDefaults.standard.set(["version": version, "build": build], forKey: Self.foundUpdateKey)
            self?.broadcast(.available(version: version))
        }
    }

    nonisolated func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        Task { @MainActor [weak self] in
            UserDefaults.standard.removeObject(forKey: Self.foundUpdateKey)
            self?.broadcast(.upToDate)
        }
    }

    nonisolated func updater(
        _ updater: SPUUpdater,
        didFinishUpdateCycleFor updateCheck: SPUUpdateCheck,
        error: (any Error)?
    ) {
        // Only stamp the timestamp on a clean cycle so a failed probe (offline)
        // retries on the next trigger instead of waiting out a whole day.
        guard error == nil else { return }
        // The same `@MainActor` hop as the two callbacks above, though this one touches
        // only `UserDefaults` and would be safe without it. The point is that all three
        // read alike: a later edit that adds actor-isolated state here inherits the
        // correct shape instead of a nonisolated body the compiler won't question.
        Task { @MainActor in
            UserDefaults.standard.set(Date(), forKey: Self.lastProbeKey)
        }
    }
}
