import Foundation
import Security

/// Names and identities shared by the app and the privileged helper. One
/// definition: a mach-service name that disagrees between the two ends is a
/// connection that fails at runtime with nothing to read.
public enum HelperConstants {
    /// The daemon's mach service, registered by launchd from the bundled plist.
    ///
    /// Not `com.loom.helper`, and the reason is worth keeping: a label is a
    /// machine-wide namespace in launchd's system domain, and a record for one can
    /// outlive the bundle that made it. During development this label accumulated
    /// registrations from bundles that were later deleted (and from an older,
    /// differently-signed `Loom.app` at the same path), after which launchd refused
    /// every spawn with `EX_CONFIG` and `needs LWCR update` — the launch constraint it
    /// derived from a previous identity could no longer be satisfied, and neither
    /// re-registering nor reinstalling cleared it. A fresh label is a fresh namespace.
    public static let machServiceName = "com.loom.proxyhelper"
    /// Filename of the LaunchDaemon plist inside
    /// `Contents/Library/LaunchDaemons/`. `SMAppService.daemon(plistName:)` takes
    /// exactly this string.
    public static let daemonPlistName = "com.loom.proxyhelper.plist"
    /// The only client the daemon serves.
    public static let appBundleIdentifier = "com.loom.app"
    /// Bumped when the XPC interface changes, so an app talking to a stale daemon
    /// can say so instead of failing in a way that reads like a permissions bug.
    public static let interfaceVersion = 1
}

/// Builds the code-signing requirement each end applies to the other.
///
/// **Why this is computed rather than a constant, and why the team clause is
/// conditional.** Loom's CI archive is signed ad-hoc (`CODE_SIGN_IDENTITY="-"`,
/// a standing decision — no Developer ID is being bought), while a local Xcode
/// build is signed with a real "Apple Development" identity. A hardcoded
/// `anchor apple generic` requirement — which is what the deleted 0.0.16 helper
/// used — can *never* be satisfied by an ad-hoc caller, so the helper refused its
/// own app on every shipped build. That refusal was read at the time as a platform
/// rule ("a root process must not accept a forgeable binary") and used to park the
/// whole feature. Only half of that was true: the platform does not refuse (an
/// ad-hoc daemon registers through `SMAppService` and loads as root after one
/// user approval — measured), and the requirement string is ours to choose.
///
/// So the requirement is as strong as the signature allows and no stronger:
/// - Signed with a real identity → `identifier` **and** the team OU. A local
///   process cannot mint a certificate carrying someone else's team, so this is a
///   real check.
/// - Ad-hoc → `identifier` alone, which is **forgeable**: any local process can
///   ad-hoc-sign a binary claiming `com.loom.app`. Treat the helper's surface as
///   reachable by anything on this machine, and keep it to operations where that
///   is acceptable — see `LoomHelperProtocol` for what is deliberately absent.
public enum HelperRequirement {
    /// Requirement the daemon applies to incoming connections.
    public static func forClient(teamIdentifier: String?) -> String {
        requirement(identifier: HelperConstants.appBundleIdentifier, teamIdentifier: teamIdentifier)
    }

    /// Requirement the app applies to the daemon it connects to. Mirrors the above
    /// so an impersonating mach service is refused by the same rule.
    public static func forDaemon(teamIdentifier: String?) -> String {
        requirement(identifier: HelperConstants.machServiceName, teamIdentifier: teamIdentifier)
    }

    private static func requirement(identifier: String, teamIdentifier: String?) -> String {
        let base = "identifier \"\(identifier)\""
        guard let team = teamIdentifier, !team.isEmpty else { return base }
        return "\(base) and certificate leaf[subject.OU] = \"\(team)\""
    }

    /// This process's own team identifier, or nil when it is signed ad-hoc.
    ///
    /// Each end derives the expected team from *itself* rather than from a
    /// hardcoded string: app and daemon ship in one bundle signed by one identity,
    /// so "whatever signed me" is exactly the right expectation, and it keeps
    /// working when the identity changes (a new certificate each year, or none).
    public static func selfTeamIdentifier() -> String? {
        var code: SecCode?
        guard SecCodeCopySelf(SecCSFlags(), &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, SecCSFlags(), &staticCode) == errSecSuccess,
              let staticCode
        else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(
            staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info
        ) == errSecSuccess, let dictionary = info as? [String: Any] else { return nil }
        return dictionary[kSecCodeInfoTeamIdentifier as String] as? String
    }
}
