import Foundation
import NIOSSL
import X509
import Testing
@testable import LoomProxyCore
import LoomSharedModels

@Suite struct CertificateAuthorityTests {
    @Test func loadOrGenerate_persistsAndReuses() throws {
        let store = InMemoryCAStore()
        let first = try CertificateAuthority.loadOrGenerate(store: store)
        let second = try CertificateAuthority.loadOrGenerate(store: store)

        #expect(!first.sha256Fingerprint.isEmpty)
        // Second call must reload the persisted CA, not mint a new one.
        #expect(first.sha256Fingerprint == second.sha256Fingerprint)
        #expect(first.certificate.subject == second.certificate.subject)
    }

    @Test func exportedPEM_isParseableCertificate() throws {
        let ca = try CertificateAuthority.loadOrGenerate(store: InMemoryCAStore())
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("loom-ca-\(UUID()).pem")
        defer { try? FileManager.default.removeItem(at: url) }

        try ca.exportCACertificate(to: url)
        let pem = try String(contentsOf: url)

        #expect(pem.contains("BEGIN CERTIFICATE"))
        // If NIOSSL can parse it, so can a system trust store.
        #expect(throws: Never.self) { try NIOSSLCertificate(bytes: Array(pem.utf8), format: .pem) }
    }

    @Test func serverContext_mintsLeafAndCachesPerHost() throws {
        let ca = try CertificateAuthority.loadOrGenerate(store: InMemoryCAStore())

        let a1 = try ca.serverContext(for: "example.test")
        let a2 = try ca.serverContext(for: "example.test")
        let b = try ca.serverContext(for: "api.other.test")

        #expect(a1 === a2, "same host should return the cached context")
        #expect(!(a1 === b), "different hosts get distinct contexts")
        // IP-literal hosts take the iPAddress-SAN path without throwing.
        #expect(throws: Never.self) { try ca.serverContext(for: "127.0.0.1") }
    }

    @Test func mintedSerials_neverExceed20Octets() throws {
        // Regression: a 21-octet serial (top random bit set → DER prepends 0x00)
        // violates RFC 5280 and makes Secure Transport reject the leaf with
        // -1015 "cannot decode raw data", silently breaking ~half of interception.
        // Mint many leaves so the ~50% case is exercised deterministically.
        let ca = try CertificateAuthority.loadOrGenerate(store: InMemoryCAStore())
        for i in 0..<200 {
            let leaf = try ca.mintLeaf(for: "host\(i).example.test")
            let octets = leaf.serialNumber.bytes.count
            #expect(octets <= 20, "leaf serial must be ≤ 20 octets (RFC 5280), got \(octets)")
            #expect(octets > 0, "serial must be positive/non-empty")
        }
    }

    @Test func mintedLeaf_carriesSKIAndAKIMatchingCA() throws {
        // Regression: strict verifiers (Python 3.13's default VERIFY_X509_STRICT)
        // reject a leaf without an Authority Key Identifier.
        let ca = try CertificateAuthority.loadOrGenerate(store: InMemoryCAStore())
        let leaf = try ca.mintLeaf(for: "aki.example.test")

        let leafSKI = try #require(try leaf.extensions.subjectKeyIdentifier)
        #expect(!leafSKI.keyIdentifier.isEmpty)

        let aki = try #require(try leaf.extensions.authorityKeyIdentifier)
        let caSKI = try #require(try ca.certificate.extensions.subjectKeyIdentifier)
        #expect(aki.keyIdentifier == caSKI.keyIdentifier,
                "leaf AKI must reference the issuing CA's SKI")
    }

    @Test func fingerprint_isColonSeparatedSHA256() throws {
        let ca = try CertificateAuthority.loadOrGenerate(store: InMemoryCAStore())
        let bytes = ca.sha256Fingerprint.split(separator: ":")
        #expect(bytes.count == 32) // SHA-256 = 32 bytes
        #expect(bytes.allSatisfy { $0.count == 2 })
    }
}

@Suite struct FileCAStoreTests {
    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("loom-ca-test-\(UUID())", isDirectory: true)
            .appendingPathComponent("ca-store.pem")
    }

    @Test func roundTrip() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = FileCAStore(fileURL: url)

        #expect(try store.load() == nil, "empty store returns nil, no prompt")

        let material = CAMaterial(certificatePEM: "-----CERT-----", privateKeyPEM: "-----KEY-----")
        try store.save(material)
        #expect(try store.load() == material)
    }

    @Test func savedFileIsOwnerOnly() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = FileCAStore(fileURL: url)
        try store.save(CAMaterial(certificatePEM: "c", privateKeyPEM: "k"))

        let perms = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        #expect(perms == 0o600, "CA private key file must be owner-read/write only")
    }

    @Test func loadableByCertificateAuthority() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = FileCAStore(fileURL: url)
        let first = try CertificateAuthority.loadOrGenerate(store: store)
        // Reload from the same file must reuse the persisted CA, not mint a new one.
        let second = try CertificateAuthority.loadOrGenerate(store: FileCAStore(fileURL: url))
        #expect(first.sha256Fingerprint == second.sha256Fingerprint)
    }
}

@Suite struct InterceptionConfigPersistenceTests {
    private func makeDefaults() -> UserDefaults {
        let suite = "com.loom.tests.\(UUID().uuidString)"
        return UserDefaults(suiteName: suite)!
    }

    @Test func scopeSurvivesReinit() {
        // Regression: SSL scope was in-memory only, so every relaunch reset to
        // disabled → all HTTPS blind-tunneled → nothing captured.
        let defaults = makeDefaults()
        let first = InterceptionConfig(defaults: defaults)
        first.update(SSLScope(enabled: true, include: ["*"], exclude: ["secure.bank.com"]))

        // A fresh config (simulating an app relaunch) must reload the saved scope.
        let reloaded = InterceptionConfig(scope: .disabled, defaults: defaults)
        let scope = reloaded.snapshot()
        #expect(scope.enabled)
        #expect(scope.include == ["*"])
        #expect(scope.exclude == ["secure.bank.com"])
        #expect(reloaded.shouldIntercept(host: "api.example.com"))
        #expect(!reloaded.shouldIntercept(host: "secure.bank.com"))
    }

    @Test func nilDefaults_doesNotPersist() {
        let hermetic = InterceptionConfig(defaults: nil)
        hermetic.update(SSLScope(enabled: true, include: ["*"]))
        #expect(hermetic.snapshot().enabled) // in-memory update still works
        // No crash, no persistence — the point is tests stay isolated.
    }
}

@Suite struct SSLScopeTests {
    @Test func wildcardMatching() {
        #expect(SSLScope.matches(pattern: "*", host: "anything.com"))
        #expect(SSLScope.matches(pattern: "example.com", host: "example.com"))
        #expect(SSLScope.matches(pattern: "EXAMPLE.com", host: "example.COM"))
        #expect(SSLScope.matches(pattern: "*.example.com", host: "api.example.com"))
        #expect(!SSLScope.matches(pattern: "*.example.com", host: "example.com"))
        #expect(SSLScope.matches(pattern: "api.*", host: "api.test"))
        #expect(SSLScope.matches(pattern: "*.foo.*", host: "a.foo.bar"))
        #expect(!SSLScope.matches(pattern: "api.example.com", host: "other.com"))
    }

    @Test func wildcardMatching_prefixAndSuffixDoNotOverlap() {
        // Regression: prefix "ab" + suffix "b" reused the same 'b', so a bare "ab"
        // wrongly matched "ab*b".
        #expect(!SSLScope.matches(pattern: "ab*b", host: "ab"))
        #expect(SSLScope.matches(pattern: "ab*b", host: "abb"))
        #expect(SSLScope.matches(pattern: "ab*b", host: "abXb"))
        // The empty-wildcard cases stay correct.
        #expect(SSLScope.matches(pattern: "a*c", host: "ac"))
        #expect(!SSLScope.matches(pattern: "a*c", host: "ab"))
    }

    @Test func shouldIntercept_respectsEnableIncludeExclude() {
        #expect(!SSLScope(enabled: false, include: ["*"]).shouldIntercept(host: "x.com"))
        #expect(SSLScope(enabled: true, include: ["*"]).shouldIntercept(host: "x.com"))
        #expect(!SSLScope(enabled: true, include: []).shouldIntercept(host: "x.com"))

        // Exclude wins over include (the pinned / pass-through list).
        let scope = SSLScope(enabled: true, include: ["*.bank.com"], exclude: ["secure.bank.com"])
        #expect(scope.shouldIntercept(host: "app.bank.com"))
        #expect(!scope.shouldIntercept(host: "secure.bank.com"))
    }
}
