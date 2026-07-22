import Foundation
import SharedModels
import os

/// Installs / removes / verifies the root CA in the **system** keychain. Trust
/// mutation goes through `/usr/bin/security add-trusted-cert`, because the
/// programmatic `SecTrustSettingsSetTrustSettings(.admin)` still triggers an
/// interactive Authorization Services prompt even when already root.
enum CertificateInstaller {
    private static let logger = Logger(subsystem: HelperIdentity.logSubsystem, category: "CertificateInstaller")

    static func install(der: Data) -> (Bool, String?) {
        withTempCert(der) { path in
            do {
                let result = try ProcessRunner.run(HelperPaths.security, [
                    "add-trusted-cert", "-d", "-r", "trustRoot",
                    "-k", HelperPaths.systemKeychain, path,
                ])
                return result.ok ? (true, nil) : (false, "add-trusted-cert: \(result.output)")
            } catch {
                return (false, error.localizedDescription)
            }
        }
    }

    static func remove(der: Data) -> (Bool, String?) {
        withTempCert(der) { path in
            do {
                let result = try ProcessRunner.run(HelperPaths.security, [
                    "remove-trusted-cert", "-d", path,
                ])
                return result.ok ? (true, nil) : (false, "remove-trusted-cert: \(result.output)")
            } catch {
                return (false, error.localizedDescription)
            }
        }
    }

    /// Best-effort: does the system keychain hold a cert with this SHA-256?
    /// `security find-certificate -a -Z` prints a `SHA-256 hash:` line per cert.
    static func isTrusted(sha256Fingerprint: String) -> Bool {
        guard let result = try? ProcessRunner.run(HelperPaths.security, [
            "find-certificate", "-a", "-Z", HelperPaths.systemKeychain,
        ]), result.ok else { return false }
        let needle = sha256Fingerprint.replacingOccurrences(of: ":", with: "").uppercased()
        for line in result.stdout.split(separator: "\n") where line.contains("SHA-256") {
            let hex = line.replacingOccurrences(of: " ", with: "").uppercased()
            if hex.contains(needle) { return true }
        }
        return false
    }

    private static func withTempCert(_ der: Data, _ body: (String) -> (Bool, String?)) -> (Bool, String?) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("loom-ca-\(UUID().uuidString).der")
        do {
            try der.write(to: url)
        } catch {
            return (false, "write temp cert: \(error.localizedDescription)")
        }
        defer { try? FileManager.default.removeItem(at: url) }
        return body(url.path)
    }
}
