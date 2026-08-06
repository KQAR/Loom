import ComposableArchitecture
import Foundation
import LoomSharedModels

/// Result of a privileged-helper operation, surfaced to the human. `message` is
/// nil for an unremarkable success; when `ok` is true AND a message is present,
/// the message is a partial-success caveat that must reach the human (e.g. the
/// proxy landed but the QUIC block didn't) — don't drop it on the ok path.
public struct HelperOutcome: Equatable, Sendable {
    public var ok: Bool
    public var message: String?
    public init(ok: Bool, message: String? = nil) {
        self.ok = ok
        self.message = message
    }

    public static let notWired = HelperOutcome(ok: false, message: "helper not installed")
}

/// TCA surface over the system-proxy operations.
///
/// The name is historical: this used to have a second half — `register` /
/// `installCA` / `removeCA` / `verifyTrusted`, an `SMAppService` + XPC path to a root
/// daemon — that was dormant by decision and has now been removed outright along with
/// the daemon itself (Loom signs ad-hoc, so launchd would never load it and the
/// daemon's own caller requirement would reject an ad-hoc caller anyway). Nothing here
/// needs privileges it doesn't take at the call: `setSystemProxy` runs `networksetup`
/// directly and escalates to one osascript admin prompt for the pf work.
@DependencyClient
public struct PrivilegedHelperClient: Sendable {
    /// Point the system proxy at `127.0.0.1:port`, or turn it **off** — disabling
    /// never hands the setting back to a previous owner (owner decision: an app
    /// that may have exited would break every request on the machine).
    public var setSystemProxy: @Sendable (_ enabled: Bool, _ port: Int) async -> HelperOutcome = { _, _ in .notWired }
    /// Whether the *effective* system proxy currently routes through Loom on
    /// `port`. Reading needs no privileges; used to sync the UI at boot.
    public var isSystemProxyActive: @Sendable (_ port: Int) async -> Bool = { _ in false }
    /// Clear a QUIC (pf) block left behind by a crash, when the system proxy no
    /// longer points at Loom. Returns whether anything was cleared. A no-op unless
    /// a block is actually recorded, so it's safe to call unconditionally at boot —
    /// which is the point: without it, a crash could leave all outbound UDP/443
    /// dropped machine-wide with no path in the UI to undo it.
    public var restoreOrphanedQUICBlock: @Sendable (_ port: Int) async -> Bool = { _ in false }
    /// The effective HTTP/HTTPS proxy settings right now. Richer than
    /// `isSystemProxyActive`: the caller can tell "nothing set" from "Charles has it".
    public var systemProxySnapshot: @Sendable () async -> SystemProxySnapshot = { .off }
    /// Every change to those settings, seeded with the current value.
    ///
    /// Exists because Loom is not the only app that sets the system proxy. Without a
    /// live watch the panel's switch went stale the moment another proxy took over,
    /// and stayed stale until the panel was reopened.
    public var systemProxySnapshots: @Sendable () -> AsyncStream<SystemProxySnapshot> = { .never }
}

extension PrivilegedHelperClient: DependencyKey {
    public static let liveValue = PrivilegedHelperClient(
        setSystemProxy: { enabled, port in
            // `networksetup` directly (silent for admin users), osascript
            // admin-prompt fallback otherwise. This is the only path there is:
            // non-admin installs stay unsupported and admins pay one prompt.
            await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    let (ok, message) = SystemProxyApplier.apply(enabled: enabled, host: "127.0.0.1", port: port)
                    continuation.resume(returning: HelperOutcome(ok: ok, message: message ?? (ok ? nil : "failed")))
                }
            }
        },
        isSystemProxyActive: { port in
            SystemProxyApplier.isPointing(port: port)
        },
        restoreOrphanedQUICBlock: { port in
            // Off the main thread: the escalation path (only reached when a block is
            // genuinely present) shows a modal prompt.
            await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    continuation.resume(returning: SystemProxyApplier.restoreOrphanedQUICBlock(port: port))
                }
            }
        },
        systemProxySnapshot: {
            SystemProxyMonitor.snapshot()
        },
        systemProxySnapshots: {
            SystemProxyMonitor.snapshots()
        }
    )

    public static let testValue = PrivilegedHelperClient()
}

public extension DependencyValues {
    var privilegedHelperClient: PrivilegedHelperClient {
        get { self[PrivilegedHelperClient.self] }
        set { self[PrivilegedHelperClient.self] = newValue }
    }
}
