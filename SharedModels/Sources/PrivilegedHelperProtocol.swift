import Foundation

// MARK: - Helper identity

/// Everything the app and the privileged helper must agree on to find and trust
/// each other. Kept in one place so the launchd plist, the XPC listener, the
/// SMAppService registration, and the caller-validation requirement never drift.
/// (Named `HelperIdentity`, not `LoomHelper`, to avoid colliding with the helper
/// target's module name.)
public enum HelperIdentity {
    /// Mach service the helper vends; must match the launchd plist `MachServices`.
    public static let machServiceName = "com.loom.helper"
    /// launchd label; must match the plist `Label` and the SMAppService plist name.
    public static let label = "com.loom.helper"
    /// Bundle IDs allowed to call the helper (the app in its build variants).
    public static let allowedCallerBundleIDs = ["com.loom.app"]
    /// os.Logger subsystem shared by app + helper.
    public static let logSubsystem = "com.loom"

    /// Apple Team ID to pin in the caller requirement. Empty for a personal /
    /// locally-signed build; a distribution build (Developer ID / notarized) sets
    /// it so the requirement also pins the team.
    public static let teamIdentifier = ""

    /// Code-signing requirement an XPC caller must satisfy, enforced by the OS via
    /// `NSXPCConnection.setCodeSigningRequirement` (audit-token based — no PID-reuse
    /// window, no private KVC accessor). `anchor apple generic` blocks an ad-hoc /
    /// self-signed impostor that merely claims our bundle id; a set `teamIdentifier`
    /// pins it to our team as well. An identifier alone (the old check) was
    /// satisfied by any locally-built binary, so the helper trusted anyone.
    public static var callerCodeRequirement: String {
        let ids = allowedCallerBundleIDs.map { "identifier \"\($0)\"" }.joined(separator: " or ")
        var requirement = "anchor apple generic and (\(ids))"
        if !teamIdentifier.isEmpty {
            requirement += " and certificate leaf[subject.OU] = \"\(teamIdentifier)\""
        }
        return requirement
    }

    /// Bumped whenever the XPC contract changes so the app can detect a stale
    /// helper after an update and re-register.
    public static let protocolVersion = 1
    /// Helper binary version, surfaced via `getHelperInfo`.
    public static let version = "0.1.0"
}

/// XPC contract between the Loom app and the privileged helper (root daemon).
///
/// The helper performs the two privileged operations the sandboxed app cannot:
/// pointing the **system** proxy at Loom and trusting Loom's root CA in the
/// **system** keychain. Every method uses the `withReply:` pattern NSXPC requires.
///
/// Runtime is UNVERIFIED here: it needs a signed/notarized app, the helper
/// embedded at `Contents/Library/LaunchDaemons`, and interactive admin approval.
@objc public protocol LoomPrivilegedHelperProtocol {
    /// Point the system HTTP+HTTPS proxy at `127.0.0.1:<port>` on every enabled
    /// network service, backing up prior settings. `ownerPID` is the app process;
    /// the helper watches it and auto-restores if the app dies (see the watchdog).
    func overrideSystemProxy(port: Int, ownerPID: Int32, withReply reply: @escaping (Bool, String?) -> Void)

    /// Restore the proxy settings captured before the last override.
    func restoreSystemProxy(withReply reply: @escaping (Bool, String?) -> Void)

    /// Current proxy state: `(isOverriddenByLoom, port)`.
    func getProxyStatus(withReply reply: @escaping (Bool, Int) -> Void)

    /// Install a DER root CA into the system keychain and mark it a trusted root.
    func installTrustedCertificate(_ der: Data, withReply reply: @escaping (Bool, String?) -> Void)

    /// Remove a previously installed root CA (DER) and its trust settings.
    func removeTrustedCertificate(_ der: Data, withReply reply: @escaping (Bool, String?) -> Void)

    /// Whether a certificate with this colon-separated uppercase SHA-256 is a
    /// trusted anchor on this machine.
    func verifyCertificateTrusted(sha256Fingerprint: String, withReply reply: @escaping (Bool) -> Void)

    /// `(version, buildOrProtocol, protocolVersion)` — for staleness checks.
    func getHelperInfo(withReply reply: @escaping (String, Int, Int) -> Void)

    /// Restore the proxy and prepare for unregistration.
    func prepareForUninstall(withReply reply: @escaping (Bool) -> Void)
}
