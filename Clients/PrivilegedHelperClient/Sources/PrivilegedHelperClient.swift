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

/// TCA surface over the system-proxy operations, and over the privileged helper
/// that makes them silent.
///
/// Two paths, one entry point. `setSystemProxy` goes through the root helper when
/// the human has installed and approved one, and otherwise runs `networksetup`
/// directly with an osascript admin prompt for the pf (QUIC) half — which is why
/// *enabling* the system proxy costs a password on every toggle without a helper:
/// `/dev/pf` is root-only, admin account or not.
///
/// The helper was deleted in 0.0.16 on the reasoning that Loom signs ad-hoc, so
/// `SMAppService` would refuse to register it and its own caller check would refuse
/// the app. Half of that was measured wrong: an ad-hoc daemon registers and loads as
/// root after one approval in System Settings. The caller check was real but
/// self-inflicted — a hardcoded `anchor apple generic` requirement. See
/// `HelperRequirement` for what replaced it and what an ad-hoc signature does and
/// does not buy.
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

    // MARK: Privileged helper

    /// Whether the root helper is installed, awaiting approval, or absent. Read at
    /// boot and after every helper action — never cached, because the human can turn
    /// it off in System Settings without telling Loom.
    public var helperState: @Sendable () async -> HelperState = { .notInstalled }
    /// Why the helper last failed to answer, when it did. Nil when it is healthy or
    /// was never tried — "not answering" with no reason is advice-shaped guessing.
    public var helperFailureReason: @Sendable () async -> String? = { nil }
    /// Register the helper. Returns the state afterwards: a first install lands on
    /// `.requiresApproval`, which is success, not failure — macOS is waiting for the
    /// human to allow it.
    public var installHelper: @Sendable () async -> (state: HelperState, error: String?) = { (.notInstalled, "helper not wired") }
    /// Unregister it. The system-proxy toggle keeps working, with a password prompt.
    public var uninstallHelper: @Sendable () async -> (state: HelperState, error: String?) = { (.notInstalled, nil) }
    /// Open the Login Items pane holding the approval switch. There is no API to
    /// flip it — that is the point of the approval.
    public var openHelperApproval: @Sendable () async -> Void = {}
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
        },
        helperState: {
            HelperInstall.state()
        },
        helperFailureReason: {
            HelperInstall.lastFailureReason
        },
        installHelper: {
            // Off the main thread: registration talks to `smd` over XPC and can block.
            await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    continuation.resume(returning: HelperInstall.install())
                }
            }
        },
        uninstallHelper: {
            await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    continuation.resume(returning: HelperInstall.uninstall())
                }
            }
        },
        openHelperApproval: {
            await MainActor.run { HelperInstall.openApprovalSettings() }
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
