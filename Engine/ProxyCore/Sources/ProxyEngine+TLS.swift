import Foundation
import LoomSharedModels

/// `TLSInterceptControlling` plus the CA surface the app reaches directly
/// (DER bytes for a keychain install, user-domain trust, exporting for a device).
/// The certificate work itself is `CertificateAuthority`/`CertificateTrust`.
extension ProxyEngine {
    public func certificateStatus() async -> CertificateStatus {
        guard let ca = ensureCA() else { return .notGenerated }
        return CertificateStatus(
            isGenerated: true,
            isTrusted: CertificateTrust.isTrusted(pem: ca.caCertificatePEM()),
            commonName: CertificateAuthority.commonName,
            sha256Fingerprint: ca.sha256Fingerprint,
            notAfter: ca.certificate.notValidAfter,
            exportedPEMPath: exportedPEMPath?.path
        )
    }

    /// DER bytes of the root CA, for a one-click keychain install via the helper.
    /// Not part of `TLSInterceptControlling` — the TCA client reaches it directly.
    public func caCertificateDER() async -> Data? {
        ensureCA()?.caCertificateDER()
    }

    /// Trust the root CA for the current user (login keychain + user-domain trust).
    /// Needs no privileged helper; macOS prompts once for the login password. Runs
    /// off the actor's executor because the prompt is modal. Returns `(ok, message)`.
    public func trustCACertificate() async -> (Bool, String?) {
        guard let der = ensureCA()?.caCertificateDER() else {
            return (false, "root CA unavailable")
        }
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                switch CertificateTrust.installUserTrust(der: der) {
                case .trusted: continuation.resume(returning: (true, nil))
                case .cancelled: continuation.resume(returning: (false, "Trust request was cancelled."))
                case let .failed(reason): continuation.resume(returning: (false, reason))
                }
            }
        }
    }

    public func exportCACertificate() async throws -> URL {
        guard let ca = ensureCA() else {
            throw ProxyControlError.certificateUnavailable("root CA could not be generated")
        }
        let url = caExportURL
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try ca.exportCACertificate(to: url)
        exportedPEMPath = url
        return url
    }

    /// Export the root CA into `directory` in both PEM and DER form, for an
    /// embedder whose device-trust flow needs the files at a known location (a
    /// device profile wants DER; `curl --cacert` and most desktop trust stores
    /// want PEM). One call instead of stitching `caCertificateDER()` +
    /// `exportCACertificate()` + a copy. Returns the written URLs.
    @discardableResult
    public func exportCA(
        toDirectory directory: URL,
        pemName: String = "loom-ca.pem",
        derName: String = "loom-ca.cer"
    ) async throws -> (pem: URL, der: URL) {
        guard let ca = ensureCA() else {
            throw ProxyControlError.certificateUnavailable("root CA could not be generated")
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let pemURL = directory.appendingPathComponent(pemName)
        let derURL = directory.appendingPathComponent(derName)
        try ca.exportCACertificate(to: pemURL)
        try ca.caCertificateDER().write(to: derURL, options: .atomic)
        exportedPEMPath = pemURL
        return (pem: pemURL, der: derURL)
    }

    public func sslScope() async -> SSLScope {
        config.snapshot()
    }

    public func setSSLScope(_ scope: SSLScope) async {
        _ = ensureCA() // make sure a CA exists before we start intercepting
        config.update(scope)
    }

    // MARK: - Mutual TLS (client certificates)

    public func clientCertificates() async -> [ClientCertificateSummary] {
        clientIdentities.summaries()
    }

    public func setClientCertificate(_ certificate: ClientCertificate) async throws {
        try clientIdentities.set(certificate)
    }

    public func deleteClientCertificate(id: UUID) async throws {
        guard clientIdentities.delete(id: id) else {
            throw ProxyControlError.clientCertificateNotFound(id)
        }
    }
}
