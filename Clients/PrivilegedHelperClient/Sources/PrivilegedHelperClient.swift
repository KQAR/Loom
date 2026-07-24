import ComposableArchitecture
import Foundation
import ServiceManagement
import LoomSharedModels

/// Result of a privileged-helper operation, surfaced to the human.
public struct HelperOutcome: Equatable, Sendable {
    public var ok: Bool
    public var message: String
    public init(ok: Bool, message: String) {
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

/// TCA surface over the root privileged helper (M2, **scaffold — unverified**).
///
/// Owns the whole privileged surface: SMAppService lifecycle plus the XPC calls
/// that point the system proxy at Loom and trust Loom's root CA. Not exercised in
/// CI — it needs a signed/notarized app with the helper embedded at
/// `Contents/Library/LaunchDaemons` and interactive admin approval. Live values
/// report failure honestly instead of pretending to succeed.
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
            // osascript admin-prompt fallback otherwise. (When the signed daemon
            // lands, this can switch to the XPC helper for non-admin installs.)
            await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    let (ok, message) = SystemProxyApplier.apply(enabled: enabled, host: "127.0.0.1", port: port)
                    continuation.resume(returning: HelperOutcome(ok: ok, message: message ?? (ok ? "ok" : "failed")))
                }
            }
        },
        isSystemProxyActive: { port in
            SystemProxyApplier.isPointing(at: "127.0.0.1", port: port)
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
