import ComposableArchitecture
import Foundation
import ServiceManagement
import LoomHelperProtocol
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

/// Outcome of trying to register the helper daemon.
public enum HelperRegistration: Equatable, Sendable {
    case enabled
    case requiresApproval   // user must approve in System Settings > Login Items
    case failed(String)
}

/// TCA surface over the privileged operations — **two halves, only one live.**
///
/// Live and shipping: `setSystemProxy` / `systemProxySnapshots`, which never touch
/// the helper (direct `networksetup`, escalating to one osascript admin prompt for
/// the pf work).
///
/// Dormant by decision: `register` / `installCA` / `removeCA` / `verifyTrusted`,
/// the SMAppService + XPC path. Loom signs ad-hoc only, so launchd will not load
/// the root daemon and the helper's caller requirement would reject an ad-hoc
/// caller anyway. Kept as a design record; see ROADMAP § M2 before scheduling any
/// work here. Live values report failure honestly instead of pretending to succeed.
@DependencyClient
public struct PrivilegedHelperClient: Sendable {
    /// Register (or confirm) the helper daemon. May require user approval.
    public var register: @Sendable () async -> HelperRegistration = { .failed("not wired") }
    /// Open System Settings > Login Items so the user can approve the daemon.
    public var openApprovalSettings: @Sendable () async -> Void
    /// Point the system proxy at `127.0.0.1:port` (or restore when disabling).
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
    /// Trust a DER root CA in the system keychain via the helper.
    public var installCA: @Sendable (_ der: Data) async -> HelperOutcome = { _ in .notWired }
    /// Remove a DER root CA and its trust settings.
    public var removeCA: @Sendable (_ der: Data) async -> HelperOutcome = { _ in .notWired }
    /// Whether a CA with this colon-separated SHA-256 is trusted system-wide.
    public var verifyTrusted: @Sendable (_ sha256Fingerprint: String) async -> Bool = { _ in false }
}

extension PrivilegedHelperClient: DependencyKey {
    private static let plistName = "\(HelperIdentity.label).plist"

    public static let liveValue = PrivilegedHelperClient(
        register: {
            let service = SMAppService.daemon(plistName: plistName)
            switch service.status {
            case .enabled:
                return .enabled
            case .requiresApproval:
                return .requiresApproval
            default:
                do {
                    try service.register()
                    return service.status == .requiresApproval ? .requiresApproval : .enabled
                } catch {
                    return .failed(error.localizedDescription)
                }
            }
        },
        openApprovalSettings: {
            SMAppService.openSystemSettingsLoginItems()
        },
        setSystemProxy: { enabled, port in
            // No-helper path: `networksetup` directly (silent for admin users),
            // osascript admin-prompt fallback otherwise. This is the permanent
            // path, not a stopgap: the XPC helper is parked (ROADMAP § M2), so
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
        installCA: { der in
            await HelperConnection.call { proxy, reply in
                proxy.installTrustedCertificate(der, withReply: reply)
            }
        },
        removeCA: { der in
            await HelperConnection.call { proxy, reply in
                proxy.removeTrustedCertificate(der, withReply: reply)
            }
        },
        verifyTrusted: { fingerprint in
            await withCheckedContinuation { continuation in
                let connection = HelperConnection.open()
                let done = OnceFlag()
                let proxy = connection.remoteObjectProxyWithErrorHandler { _ in
                    if done.take() { connection.invalidate(); continuation.resume(returning: false) }
                } as? LoomPrivilegedHelperProtocol
                guard let proxy else {
                    if done.take() { continuation.resume(returning: false) }
                    return
                }
                proxy.verifyCertificateTrusted(sha256Fingerprint: fingerprint) { trusted in
                    if done.take() { connection.invalidate(); continuation.resume(returning: trusted) }
                }
            }
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

/// XPC plumbing for `(Bool, String?)`-replying helper methods. The connection
/// fails cleanly (rather than hanging) until the helper is installed.
private enum HelperConnection {
    static func open() -> NSXPCConnection {
        let connection = NSXPCConnection(machServiceName: HelperIdentity.machServiceName, options: .privileged)
        connection.remoteObjectInterface = NSXPCInterface(with: LoomPrivilegedHelperProtocol.self)
        connection.resume()
        return connection
    }

    static func call(
        _ body: @escaping (LoomPrivilegedHelperProtocol, @escaping (Bool, String?) -> Void) -> Void
    ) async -> HelperOutcome {
        await withCheckedContinuation { continuation in
            let connection = open()
            let done = OnceFlag()
            func finish(_ outcome: HelperOutcome) {
                if done.take() {
                    connection.invalidate()
                    continuation.resume(returning: outcome)
                }
            }
            let proxy = connection.remoteObjectProxyWithErrorHandler { error in
                finish(.init(ok: false, message: "helper unavailable: \(error.localizedDescription)"))
            } as? LoomPrivilegedHelperProtocol
            guard let proxy else {
                finish(.init(ok: false, message: "helper proxy unavailable"))
                return
            }
            body(proxy) { ok, message in
                finish(.init(ok: ok, message: message ?? (ok ? "ok" : "failed")))
            }
        }
    }
}

/// One-shot guard so a continuation resumes exactly once across the XPC reply
/// and error-handler races.
private final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false
    func take() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if fired { return false }
        fired = true
        return true
    }
}
