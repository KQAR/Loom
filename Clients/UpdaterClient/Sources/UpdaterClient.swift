import ComposableArchitecture
import Foundation

/// Availability of a newer release, surfaced to the status-bar panel so the
/// footer button can switch from a low-key "Check for Updates" to a prominent
/// "Update" call-to-action. `.unknown` until the first probe answers.
public enum UpdateAvailability: Equatable, Sendable {
    case unknown
    case upToDate
    case available(version: String)

    /// True only when a newer version is ready — drives the "upgrade" styling.
    public var hasUpdate: Bool {
        if case .available = self { return true }
        return false
    }
}

/// TCA surface over Sparkle (the same auto-update engine `looper` uses). The UI
/// and reducers reach the updater only through this client — Sparkle types never
/// leak past the module boundary. Follows the `ProxyClient` three-part shape.
///
/// Cadence: `checkInBackgroundIfDue` runs a silent probe at most once a day and
/// only flips the button style; the user-initiated `checkForUpdates` shows
/// Sparkle's standard download/install UI.
@DependencyClient
public struct UpdaterClient: Sendable {
    /// Whether Sparkle can run a user-initiated check right now.
    public var canCheckForUpdates: @Sendable () async -> Bool = { false }
    /// Availability changes; replays the last known value on subscribe.
    public var availabilityStream: @Sendable () async -> AsyncStream<UpdateAvailability> = { .finished }
    /// User-initiated check — shows Sparkle's install UI regardless of the last probe.
    public var checkForUpdates: @Sendable () async -> Void
    /// Silent once-a-day probe. No UI; only updates `availabilityStream`.
    public var checkInBackgroundIfDue: @Sendable () async -> Void
}

extension UpdaterClient: DependencyKey {
    public static let liveValue = UpdaterClient(
        canCheckForUpdates: { await UpdaterCoordinator.shared.canCheckForUpdates },
        availabilityStream: { await UpdaterCoordinator.shared.availabilityStream() },
        checkForUpdates: { await UpdaterCoordinator.shared.checkForUpdates() },
        checkInBackgroundIfDue: { await UpdaterCoordinator.shared.checkInBackgroundIfDue() }
    )

    public static let testValue = UpdaterClient()
}

public extension DependencyValues {
    var updaterClient: UpdaterClient {
        get { self[UpdaterClient.self] }
        set { self[UpdaterClient.self] = newValue }
    }
}
