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
    private static let probeInterval: TimeInterval = 24 * 60 * 60
    private static let lastProbeKey = "com.loom.lastUpdateCheck"

    private var controller: SPUStandardUpdaterController!
    private var continuations: [UUID: AsyncStream<UpdateAvailability>.Continuation] = [:]
    /// Last availability we learned, replayed to every new subscriber.
    private var current: UpdateAvailability = .unknown

    override init() {
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
        Task { @MainActor [weak self] in self?.broadcast(.available(version: version)) }
    }

    nonisolated func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        Task { @MainActor [weak self] in self?.broadcast(.upToDate) }
    }

    nonisolated func updater(
        _ updater: SPUUpdater,
        didFinishUpdateCycleFor updateCheck: SPUUpdateCheck,
        error: (any Error)?
    ) {
        // Only stamp the timestamp on a clean cycle so a failed probe (offline)
        // retries on the next trigger instead of waiting out a whole day.
        guard error == nil else { return }
        UserDefaults.standard.set(Date(), forKey: Self.lastProbeKey)
    }
}
