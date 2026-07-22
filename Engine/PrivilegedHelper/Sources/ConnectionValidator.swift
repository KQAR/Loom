import Foundation
import SharedModels
import Security
import os

/// Decides whether an incoming XPC connection is really the Loom app, so a
/// random process can't drive the root helper. Two layers:
///   1. the caller's code satisfies a designated requirement built from the
///      allowed bundle identifiers, and
///   2. that check is done against the caller's **audit token** (immune to PID
///      reuse), not just its PID.
///
/// A personal app signed "to run locally" has no Team ID, so this validates on
/// bundle identifier. A production build should tighten the requirement to pin
/// the Apple Team ID as well.
enum ConnectionValidator {
    private static let logger = Logger(subsystem: HelperIdentity.logSubsystem, category: "ConnectionValidator")

    static func isTrustedCaller(_ connection: NSXPCConnection) -> Bool {
        guard let requirement = designatedRequirement() else {
            logger.error("could not build caller requirement")
            return false
        }
        guard let tokenData = auditToken(of: connection), let code = secCode(from: tokenData) else {
            logger.error("no audit token for pid \(connection.processIdentifier)")
            return false
        }
        let ok = SecCodeCheckValidity(code, SecCSFlags(rawValue: 0), requirement) == errSecSuccess
        if !ok { logger.error("caller pid \(connection.processIdentifier) failed requirement") }
        return ok
    }

    /// `identifier "a" or identifier "b" …` over the allowed bundle IDs.
    private static func designatedRequirement() -> SecRequirement? {
        let clause = HelperIdentity.allowedCallerBundleIDs
            .map { "identifier \"\($0)\"" }
            .joined(separator: " or ")
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(clause as CFString, [], &requirement) == errSecSuccess else {
            return nil
        }
        return requirement
    }

    /// The connection's audit token via KVC (no public accessor exists).
    private static func auditToken(of connection: NSXPCConnection) -> Data? {
        guard let value = connection.value(forKey: "auditToken") else { return nil }
        if let data = value as? Data { return data }
        guard let nsValue = value as? NSValue else { return nil }
        var token = audit_token_t()
        let size = MemoryLayout<audit_token_t>.size
        nsValue.getValue(&token, size: size)
        return withUnsafeBytes(of: &token) { Data($0) }
    }

    private static func secCode(from tokenData: Data) -> SecCode? {
        let attributes = [kSecGuestAttributeAudit: tokenData] as CFDictionary
        var code: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &code) == errSecSuccess else { return nil }
        return code
    }
}
