import Crypto
import Foundation
import NIOSSL
import SharedModels
import SwiftASN1
import X509

/// Loom's man-in-the-middle certificate authority. A P-256 root CA is generated
/// once and persisted (Keychain in production); per-host leaf certificates are
/// minted on demand, signed by the root, and cached as ready-to-use TLS server
/// contexts. Thread-safe (`NSLock`) so NIO handlers can pull a context for a host
/// synchronously during the CONNECT handshake.
final class CertificateAuthority: @unchecked Sendable {
    let certificate: Certificate
    /// Colon-separated uppercase SHA-256 of the CA certificate (DER).
    let sha256Fingerprint: String

    private let privateKey: Certificate.PrivateKey
    private let caPEM: String
    private let leafKey: Certificate.PrivateKey
    private let nioLeafKey: NIOSSLPrivateKey
    private let nioCACert: NIOSSLCertificate

    private let lock = NSLock()
    private var contextCache: [String: NIOSSLContext] = [:]

    static let commonName = "Loom Root CA"

    // MARK: Load or generate

    static func loadOrGenerate(store: CAStore) throws -> CertificateAuthority {
        if let material = try? store.load(),
           let existing = try? CertificateAuthority(material: material) {
            return existing
        }
        let material = try generateMaterial()
        try store.save(material)
        return try CertificateAuthority(material: material)
    }

    private init(material: CAMaterial) throws {
        let cert = try Certificate(pemEncoded: material.certificatePEM)
        certificate = cert
        privateKey = try Certificate.PrivateKey(pemEncoded: material.privateKeyPEM)
        caPEM = material.certificatePEM

        // One leaf key reused across all hosts — matches how MITM proxies work
        // and keeps per-host minting to just a signature.
        let leaf = Certificate.PrivateKey(P256.Signing.PrivateKey())
        leafKey = leaf
        nioLeafKey = try NIOSSLPrivateKey(bytes: Array(leaf.serializeAsPEM().pemString.utf8), format: .pem)
        nioCACert = try NIOSSLCertificate(bytes: Array(material.certificatePEM.utf8), format: .pem)

        var serializer = DER.Serializer()
        try serializer.serialize(cert)
        let digest = SHA256.hash(data: Data(serializer.serializedBytes))
        sha256Fingerprint = digest.map { String(format: "%02X", $0) }.joined(separator: ":")
    }

    private static func generateMaterial() throws -> CAMaterial {
        let key = Certificate.PrivateKey(P256.Signing.PrivateKey())
        let name = try DistinguishedName {
            CommonName(commonName)
            OrganizationName("Loom")
        }
        let now = Date()
        let cert = try Certificate(
            version: .v3,
            serialNumber: Self.makeSerialNumber(),
            publicKey: key.publicKey,
            notValidBefore: now.addingTimeInterval(-3600),
            notValidAfter: now.addingTimeInterval(60 * 60 * 24 * 3650), // ~10 years
            issuer: name,
            subject: name,
            extensions: try Certificate.Extensions {
                Critical(BasicConstraints.isCertificateAuthority(maxPathLength: nil))
                Critical(KeyUsage(keyCertSign: true, cRLSign: true))
                SubjectKeyIdentifier(hash: key.publicKey)
            },
            issuerPrivateKey: key
        )
        return CAMaterial(
            certificatePEM: try cert.serializeAsPEM().pemString,
            privateKeyPEM: try key.serializeAsPEM().pemString
        )
    }

    // MARK: TLS contexts

    /// A server-side `NIOSSLContext` presenting a freshly-minted (cached) leaf
    /// for `host`, chained to the root CA.
    func serverContext(for host: String) throws -> NIOSSLContext {
        lock.lock()
        defer { lock.unlock() }
        if let cached = contextCache[host] { return cached }

        let leaf = try mintLeaf(for: host)
        let nioLeaf = try NIOSSLCertificate(bytes: Array(leaf.serializeAsPEM().pemString.utf8), format: .pem)
        var config = TLSConfiguration.makeServerConfiguration(
            certificateChain: [.certificate(nioLeaf), .certificate(nioCACert)],
            privateKey: .privateKey(nioLeafKey)
        )
        // Advertise HTTP/2 so h2 clients negotiate it (we demux + capture per
        // stream); http/1.1 stays the fallback. A client that offers neither just
        // gets http/1.1.
        config.applicationProtocols = ["h2", "http/1.1"]
        let context = try NIOSSLContext(configuration: config)
        contextCache[host] = context
        return context
    }

    /// Internal (not private) so tests can inspect the minted certificate directly.
    func mintLeaf(for host: String) throws -> Certificate {
        let subject = try DistinguishedName { CommonName(host) }
        let now = Date()
        return try Certificate(
            version: .v3,
            serialNumber: Self.makeSerialNumber(),
            publicKey: leafKey.publicKey,
            notValidBefore: now.addingTimeInterval(-3600),
            notValidAfter: now.addingTimeInterval(60 * 60 * 24 * 397), // < 398d, Apple's leaf cap
            issuer: certificate.subject,
            subject: subject,
            extensions: try Certificate.Extensions {
                Critical(BasicConstraints.notCertificateAuthority)
                KeyUsage(digitalSignature: true)
                try ExtendedKeyUsage([.serverAuth])
                SubjectAlternativeNames([Self.generalName(for: host)])
            },
            issuerPrivateKey: privateKey
        )
    }

    /// A random positive serial guaranteed to encode as **≤ 20 octets** of DER.
    ///
    /// `Certificate.SerialNumber()` draws 20 random bytes and normalises to ASN.1
    /// INTEGER form; when the top bit of the first byte is set it prepends `0x00`
    /// to stay positive, yielding a **21-octet** serial. That violates RFC 5280
    /// (§4.1.2.2: serials MUST NOT exceed 20 octets) and — critically — makes
    /// Apple's Secure Transport reject the cert with `-1015 "cannot decode raw
    /// data"` and LibreSSL with an ASN.1 error, so ~half of minted leaves silently
    /// break interception. Clearing the top bit keeps it a positive 20-octet serial
    /// (159 bits of entropy — ample for collision resistance).
    private static func makeSerialNumber() -> Certificate.SerialNumber {
        var bytes = [UInt8](repeating: 0, count: 20)
        for i in bytes.indices { bytes[i] = UInt8.random(in: .min ... .max) }
        bytes[0] &= 0x7F                       // clear high bit → no 0x00 prefix, ≤ 20 octets
        if bytes[0] == 0 { bytes[0] = 0x01 }   // keep it a full, nonzero 20-octet serial
        return Certificate.SerialNumber(bytes: bytes)
    }

    /// An IP-literal host becomes an `iPAddress` SAN; anything else a `dNSName`.
    private static func generalName(for host: String) -> GeneralName {
        var v4 = in_addr()
        if inet_pton(AF_INET, host, &v4) == 1 {
            let bytes = withUnsafeBytes(of: v4.s_addr) { Array($0) }
            return .ipAddress(ASN1OctetString(contentBytes: bytes[...]))
        }
        var v6 = in6_addr()
        if inet_pton(AF_INET6, host, &v6) == 1 {
            let bytes = withUnsafeBytes(of: v6) { Array($0) }
            return .ipAddress(ASN1OctetString(contentBytes: bytes[...]))
        }
        return .dnsName(host)
    }

    // MARK: Export

    func caCertificatePEM() -> String { caPEM }

    /// DER bytes of the CA certificate — what the privileged helper wants for a
    /// keychain install.
    func caCertificateDER() -> Data {
        var serializer = DER.Serializer()
        // Force-try is safe: the certificate was already serialized at init.
        try! serializer.serialize(certificate)
        return Data(serializer.serializedBytes)
    }

    /// Write the CA certificate (PEM) to disk so the human can trust it.
    @discardableResult
    func exportCACertificate(to url: URL) throws -> URL {
        try Data(caPEM.utf8).write(to: url, options: .atomic)
        return url
    }
}
