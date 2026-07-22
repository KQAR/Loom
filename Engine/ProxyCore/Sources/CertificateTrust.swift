import Foundation
import Security

/// Best-effort answer to "is Loom's root CA trusted on this machine?" — used to
/// surface the not-yet-trusted fault and to fill `CertificateStatus.isTrusted`.
/// It cannot mutate trust (that needs the privileged helper); it only reads.
enum CertificateTrust {
    /// Evaluate the (self-signed) CA as its own leaf against a basic X.509 policy.
    /// This succeeds only when the certificate is installed as a trusted anchor.
    static func isTrusted(pem: String) -> Bool {
        guard let certificate = secCertificate(fromPEM: pem) else { return false }
        let policy = SecPolicyCreateBasicX509()
        var trust: SecTrust?
        guard SecTrustCreateWithCertificates(certificate, policy, &trust) == errSecSuccess,
              let trust
        else { return false }
        var error: CFError?
        return SecTrustEvaluateWithError(trust, &error)
    }

    /// Result of an in-app trust attempt.
    enum TrustInstallResult: Equatable {
        case trusted
        case cancelled
        case failed(String)
    }

    /// Trust the CA for the **current user**, no privileged helper required: add it
    /// to the login keychain and set user-domain trust settings. macOS prompts once
    /// for the login password (Authorization Services). Safari and apps that use the
    /// system trust evaluation then accept Loom's leaf certs.
    ///
    /// Must run OFF the main thread — the password prompt is modal.
    static func installUserTrust(der: Data) -> TrustInstallResult {
        guard let certificate = SecCertificateCreateWithData(nil, der as CFData) else {
            return .failed("invalid certificate data")
        }

        // Add to the default (login) keychain; a duplicate is fine (re-trusting).
        let addStatus = SecItemAdd([
            kSecClass as String: kSecClassCertificate,
            kSecValueRef as String: certificate,
        ] as CFDictionary, nil)
        if addStatus != errSecSuccess, addStatus != errSecDuplicateItem {
            return .failed("keychain add failed (OSStatus \(addStatus))")
        }

        // Trust as a root for all policies in the user domain ("Always Trust").
        let settings: [[String: Any]] = [[
            kSecTrustSettingsResult as String: NSNumber(value: SecTrustSettingsResult.trustRoot.rawValue),
        ]]
        let status = SecTrustSettingsSetTrustSettings(certificate, .user, settings as CFArray)
        switch status {
        case errSecSuccess: return .trusted
        case errSecUserCanceled: return .cancelled
        default: return .failed("setting trust failed (OSStatus \(status))")
        }
    }

    static func secCertificate(fromPEM pem: String) -> SecCertificate? {
        guard let der = derBytes(fromPEM: pem) else { return nil }
        return SecCertificateCreateWithData(nil, der as CFData)
    }

    private static func derBytes(fromPEM pem: String) -> Data? {
        let base64 = pem
            .split(separator: "\n")
            .filter { !$0.hasPrefix("-----") }
            .joined()
        return Data(base64Encoded: base64)
    }
}
