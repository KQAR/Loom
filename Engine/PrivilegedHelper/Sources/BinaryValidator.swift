import Foundation
import Synchronization
import LoomHelperProtocol
import Security
import os

/// Validates that a system binary is Apple-signed before the (root) helper execs
/// it. Without this, a path-hijacked `networksetup`/`security` would run as root.
/// Results are cached per path for the daemon's lifetime — system binaries don't
/// change mid-run.
enum BinaryValidator {
    private static let logger = Logger(subsystem: HelperIdentity.logSubsystem, category: "BinaryValidator")
    /// Inside a `Mutex`, so the `nonisolated(unsafe)` that used to carry this — with
    /// a comment asserting the discipline — is gone.
    private static let cache = Mutex<[String: Bool]>([:])

    static func isAppleSigned(at path: String) -> Bool {
        // Two critical sections: the signature check is a syscall-heavy Security
        // call and must not run under the lock.
        if let cached = cache.withLock({ $0[path] }) { return cached }
        let result = validate(path)
        cache.withLock { $0[path] = result }
        return result
    }

    private static func validate(_ path: String) -> Bool {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL, [], &staticCode) == errSecSuccess,
              let code = staticCode
        else {
            logger.error("cannot create static code for \(path, privacy: .public)")
            return false
        }
        guard SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: 0), nil) == errSecSuccess else {
            logger.error("invalid signature for \(path, privacy: .public)")
            return false
        }
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString("anchor apple" as CFString, [], &requirement) == errSecSuccess,
              let requirement
        else { return false }
        let anchored = SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: 0), requirement) == errSecSuccess
        if !anchored { logger.error("\(path, privacy: .public) is not Apple-anchored") }
        return anchored
    }
}
