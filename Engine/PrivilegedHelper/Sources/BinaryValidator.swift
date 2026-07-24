import Foundation
import LoomSharedModels
import Security
import os

/// Validates that a system binary is Apple-signed before the (root) helper execs
/// it. Without this, a path-hijacked `networksetup`/`security` would run as root.
/// Results are cached per path for the daemon's lifetime — system binaries don't
/// change mid-run.
enum BinaryValidator {
    private static let logger = Logger(subsystem: HelperIdentity.logSubsystem, category: "BinaryValidator")
    private static let lock = NSLock()
    private static var cache: [String: Bool] = [:]

    static func isAppleSigned(at path: String) -> Bool {
        lock.lock()
        if let cached = cache[path] { lock.unlock(); return cached }
        lock.unlock()

        let result = validate(path)

        lock.lock(); cache[path] = result; lock.unlock()
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
