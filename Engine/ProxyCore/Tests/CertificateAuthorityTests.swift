import NIOSSL
import XCTest
@testable import ProxyCore
import SharedModels

final class CertificateAuthorityTests: XCTestCase {
    func test_loadOrGenerate_persistsAndReuses() throws {
        let store = InMemoryCAStore()
        let first = try CertificateAuthority.loadOrGenerate(store: store)
        let second = try CertificateAuthority.loadOrGenerate(store: store)

        XCTAssertFalse(first.sha256Fingerprint.isEmpty)
        // Second call must reload the persisted CA, not mint a new one.
        XCTAssertEqual(first.sha256Fingerprint, second.sha256Fingerprint)
        XCTAssertEqual(first.certificate.subject, second.certificate.subject)
    }

    func test_exportedPEM_isParseableCertificate() throws {
        let ca = try CertificateAuthority.loadOrGenerate(store: InMemoryCAStore())
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("loom-ca-\(UUID()).pem")
        defer { try? FileManager.default.removeItem(at: url) }

        try ca.exportCACertificate(to: url)
        let pem = try String(contentsOf: url)

        XCTAssertTrue(pem.contains("BEGIN CERTIFICATE"))
        // If NIOSSL can parse it, so can a system trust store.
        XCTAssertNoThrow(try NIOSSLCertificate(bytes: Array(pem.utf8), format: .pem))
    }

    func test_serverContext_mintsLeafAndCachesPerHost() throws {
        let ca = try CertificateAuthority.loadOrGenerate(store: InMemoryCAStore())

        let a1 = try ca.serverContext(for: "example.test")
        let a2 = try ca.serverContext(for: "example.test")
        let b = try ca.serverContext(for: "api.other.test")

        XCTAssertTrue(a1 === a2, "same host should return the cached context")
        XCTAssertFalse(a1 === b, "different hosts get distinct contexts")
        // IP-literal hosts take the iPAddress-SAN path without throwing.
        XCTAssertNoThrow(try ca.serverContext(for: "127.0.0.1"))
    }

    func test_mintedSerials_neverExceed20Octets() throws {
        // Regression: a 21-octet serial (top random bit set → DER prepends 0x00)
        // violates RFC 5280 and makes Secure Transport reject the leaf with
        // -1015 "cannot decode raw data", silently breaking ~half of interception.
        // Mint many leaves so the ~50% case is exercised deterministically.
        let ca = try CertificateAuthority.loadOrGenerate(store: InMemoryCAStore())
        for i in 0..<200 {
            let leaf = try ca.mintLeaf(for: "host\(i).example.test")
            let octets = leaf.serialNumber.bytes.count
            XCTAssertLessThanOrEqual(octets, 20, "leaf serial must be ≤ 20 octets (RFC 5280), got \(octets)")
            XCTAssertGreaterThan(octets, 0, "serial must be positive/non-empty")
        }
    }

    func test_fingerprint_isColonSeparatedSHA256() throws {
        let ca = try CertificateAuthority.loadOrGenerate(store: InMemoryCAStore())
        let bytes = ca.sha256Fingerprint.split(separator: ":")
        XCTAssertEqual(bytes.count, 32) // SHA-256 = 32 bytes
        XCTAssertTrue(bytes.allSatisfy { $0.count == 2 })
    }
}

final class InterceptionConfigPersistenceTests: XCTestCase {
    private func makeDefaults() -> UserDefaults {
        let suite = "com.loom.tests.\(UUID().uuidString)"
        return UserDefaults(suiteName: suite)!
    }

    func test_scopeSurvivesReinit() {
        // Regression: SSL scope was in-memory only, so every relaunch reset to
        // disabled → all HTTPS blind-tunneled → nothing captured.
        let defaults = makeDefaults()
        let first = InterceptionConfig(defaults: defaults)
        first.update(SSLScope(enabled: true, include: ["*"], exclude: ["secure.bank.com"]))

        // A fresh config (simulating an app relaunch) must reload the saved scope.
        let reloaded = InterceptionConfig(scope: .disabled, defaults: defaults)
        let scope = reloaded.snapshot()
        XCTAssertTrue(scope.enabled)
        XCTAssertEqual(scope.include, ["*"])
        XCTAssertEqual(scope.exclude, ["secure.bank.com"])
        XCTAssertTrue(reloaded.shouldIntercept(host: "api.example.com"))
        XCTAssertFalse(reloaded.shouldIntercept(host: "secure.bank.com"))
    }

    func test_nilDefaults_doesNotPersist() {
        let hermetic = InterceptionConfig(defaults: nil)
        hermetic.update(SSLScope(enabled: true, include: ["*"]))
        XCTAssertTrue(hermetic.snapshot().enabled) // in-memory update still works
        // No crash, no persistence — the point is tests stay isolated.
    }
}

final class SSLScopeTests: XCTestCase {
    func test_wildcardMatching() {
        XCTAssertTrue(SSLScope.matches(pattern: "*", host: "anything.com"))
        XCTAssertTrue(SSLScope.matches(pattern: "example.com", host: "example.com"))
        XCTAssertTrue(SSLScope.matches(pattern: "EXAMPLE.com", host: "example.COM"))
        XCTAssertTrue(SSLScope.matches(pattern: "*.example.com", host: "api.example.com"))
        XCTAssertFalse(SSLScope.matches(pattern: "*.example.com", host: "example.com"))
        XCTAssertTrue(SSLScope.matches(pattern: "api.*", host: "api.test"))
        XCTAssertTrue(SSLScope.matches(pattern: "*.foo.*", host: "a.foo.bar"))
        XCTAssertFalse(SSLScope.matches(pattern: "api.example.com", host: "other.com"))
    }

    func test_shouldIntercept_respectsEnableIncludeExclude() {
        XCTAssertFalse(SSLScope(enabled: false, include: ["*"]).shouldIntercept(host: "x.com"))
        XCTAssertTrue(SSLScope(enabled: true, include: ["*"]).shouldIntercept(host: "x.com"))
        XCTAssertFalse(SSLScope(enabled: true, include: []).shouldIntercept(host: "x.com"))

        // Exclude wins over include (the pinned / pass-through list).
        let scope = SSLScope(enabled: true, include: ["*.bank.com"], exclude: ["secure.bank.com"])
        XCTAssertTrue(scope.shouldIntercept(host: "app.bank.com"))
        XCTAssertFalse(scope.shouldIntercept(host: "secure.bank.com"))
    }
}
