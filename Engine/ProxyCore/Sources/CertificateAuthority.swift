import Crypto
import Foundation
import Synchronization
import NIOSSL
import LoomSharedModels
import SwiftASN1
import X509

/// Loom's man-in-the-middle certificate authority. A P-256 root CA is generated
/// once and persisted (Keychain in production); per-host leaf certificates are
/// minted on demand, signed by the root, and cached as ready-to-use TLS server
/// contexts — LRU-bounded to `contextCacheCapacity` hosts. Thread-safe (`Mutex`)
/// so NIO handlers can pull a context for a host synchronously during the CONNECT
/// handshake.
final class CertificateAuthority: Sendable {
    let certificate: Certificate
    /// Colon-separated uppercase SHA-256 of the CA certificate (DER).
    let sha256Fingerprint: String

    private let privateKey: Certificate.PrivateKey
    private let caPEM: String
    private let leafKey: Certificate.PrivateKey
    private let nioLeafKey: NIOSSLPrivateKey
    private let nioCACert: NIOSSLCertificate
    /// Key identifier of the CA, embedded as each leaf's AKI. Falls back to the
    /// RFC 5280 public-key hash for a legacy CA persisted without an SKI.
    private let issuerKeyIdentifier: ArraySlice<UInt8>

    /// The bounded per-host context cache. `cache` and `order` must move together —
    /// an entry present in one and not the other is either a leak or an eviction that
    /// frees nothing — so they share one lock, and now one `Mutex` value.
    private struct ContextCache {
        var contexts: [String: NIOSSLContext] = [:]
        /// Hosts in least-recently-used order (oldest first), so the cache can be
        /// bounded like every other in-memory collection in the engine.
        var order: [String] = []

        /// Move `host` to the most-recently-used end. Called on a cache hit, i.e. once
        /// per TLS handshake — not per request — so the O(n) shuffle over at most
        /// `contextCacheCapacity` entries is nothing next to the handshake itself.
        mutating func touch(_ host: String) {
            guard let idx = order.firstIndex(of: host) else {
                order.append(host)
                return
            }
            guard idx != order.index(before: order.endIndex) else { return }
            order.remove(at: idx)
            order.append(host)
        }

        mutating func evict(capacity: Int) {
            while order.count > capacity {
                let oldest = order.removeFirst()
                contexts.removeValue(forKey: oldest)
            }
        }
    }

    private let cache = Mutex(ContextCache())
    /// Which hosts must be served HTTP/1.1. Injected so a test can drive the decision
    /// without touching the process-wide registry a parallel suite also reads.
    private let downgrades: HTTP2DowngradeRegistry
    /// Above this many hosts the least-recently-used context is dropped. A
    /// `NIOSSLContext` wraps BoringSSL state, so this is heavier per entry than a
    /// typical cache row, and a long session across thousands of distinct MITM'd
    /// hosts would otherwise grow without limit. An evicted host just re-mints on
    /// its next handshake (one signature) — no correctness cost.
    static let contextCacheCapacity = 512

    static let commonName = "Loom Root CA"

    // MARK: Load or generate

    static func loadOrGenerate(store: CAStore) throws -> CertificateAuthority {
        if let material = try? store.load(),
           let existing = try? CertificateAuthority(material: material) {
            return existing
        }
        // No usable CA on disk — mint a fresh one. If a previously-trusted CA was
        // present but corrupt, this orphans it (clients will distrust the new
        // leaf until the human re-trusts), so make that loud.
        Log.tls.notice("No usable CA loaded; generating a new root CA.")
        let material = try generateMaterial()
        try store.save(material)
        return try CertificateAuthority(material: material)
    }

    private init(material: CAMaterial, downgrades: HTTP2DowngradeRegistry = .shared) throws {
        self.downgrades = downgrades
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

        if let ski = (try? cert.extensions.subjectKeyIdentifier) ?? nil {
            issuerKeyIdentifier = ski.keyIdentifier
        } else {
            issuerKeyIdentifier = SubjectKeyIdentifier(hash: cert.publicKey).keyIdentifier
        }

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
        try cache.withLock { cache in
            if let cached = cache.contexts[host] {
                cache.touch(host)
                return cached
            }

            let leaf = try mintLeaf(for: host)
            let nioLeaf = try NIOSSLCertificate(bytes: Array(leaf.serializeAsPEM().pemString.utf8), format: .pem)
            var config = TLSConfiguration.makeServerConfiguration(
                certificateChain: [.certificate(nioLeaf), .certificate(nioCACert)],
                privateKey: .privateKey(nioLeafKey)
            )
            // Advertise HTTP/2 so h2 clients negotiate it (we demux + capture per
            // stream); http/1.1 stays the fallback. A client that offers neither just
            // gets http/1.1.
            //
            // **Unless this host has been downgraded** — then h2 is withheld and the
            // client negotiates HTTP/1.1 by itself, which is the only lever Loom has
            // against SwiftNIO's pre-ACK 16 KB HPACK limit (see
            // `HTTP2DowngradeRegistry`). Withholding it here rather than tearing the
            // stack down later is what makes the client's own ALPN do the work: it
            // never speaks h2 to Loom, so there is no header block to refuse.
            config.applicationProtocols =
                downgrades.isDowngraded(host: host) ? ["http/1.1"] : ["h2", "http/1.1"]
            let context = try NIOSSLContext(configuration: config)
            cache.contexts[host] = context
            cache.order.append(host)
            cache.evict(capacity: Self.contextCacheCapacity)
            return context
        }
    }

    /// Drop the cached context for one host, so the next connection is built with a
    /// fresh ALPN list.
    ///
    /// The cache is keyed on the host alone, so a downgrade decided *after* a context
    /// was built would otherwise keep offering `h2` for as long as that entry lived —
    /// the same stale-context trap `ClientCertificateConfig` documents for an edited
    /// identity, and here it would make the workaround silently not work.
    func invalidateContext(for host: String) {
        cache.withLock { cache in
            cache.contexts.removeValue(forKey: host)
            cache.order.removeAll { $0 == host }
        }
    }

    /// Test seam: how many host contexts are currently held.
    var cachedContextCount: Int {
        cache.withLock { $0.contexts.count }
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
                // SKI + AKI are required by strict verifiers (e.g. Python 3.13's
                // default VERIFY_X509_STRICT rejects leaves without an AKI).
                SubjectKeyIdentifier(hash: leafKey.publicKey)
                AuthorityKeyIdentifier(keyIdentifier: issuerKeyIdentifier)
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
