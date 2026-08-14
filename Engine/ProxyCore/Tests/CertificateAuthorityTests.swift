import Foundation
import NIOCore
import NIOEmbedded
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

    @Test func serverContext_cacheKeyIsCaseInsensitive() throws {
        // DNS is case-insensitive and nothing normalizes the host a client sent.
        // A second CONNECT with different case must not keep a stale context that
        // still advertises `h2` after a downgrade invalidated the folded name.
        let ca = try CertificateAuthority.loadOrGenerate(store: InMemoryCAStore())
        let a = try ca.serverContext(for: "API.Example.TEST")
        let b = try ca.serverContext(for: "api.example.test")
        #expect(a === b)
        #expect(ca.cachedContextCount == 1)
        ca.invalidateContext(for: "Api.Example.Test")
        #expect(ca.cachedContextCount == 0)
    }

    @Test func serverContext_cacheIsBoundedAndEvictsLeastRecentlyUsed() throws {
        // Regression: contextCache was the one collection in the engine with no
        // cap, so a long session across many distinct MITM'd hosts grew live
        // NIOSSLContext (BoringSSL) state without limit.
        let ca = try CertificateAuthority.loadOrGenerate(store: InMemoryCAStore())
        let capacity = CertificateAuthority.contextCacheCapacity

        let first = try ca.serverContext(for: "host0.example.test")
        for i in 1 ..< capacity {
            _ = try ca.serverContext(for: "host\(i).example.test")
        }
        #expect(ca.cachedContextCount == capacity)

        // Re-touch the oldest host so it becomes most-recently-used, then overflow.
        #expect(try ca.serverContext(for: "host0.example.test") === first)
        _ = try ca.serverContext(for: "overflow.example.test")

        #expect(ca.cachedContextCount == capacity, "cache must stay at its cap")
        // host0 was touched, so host1 is now the least-recently-used victim.
        #expect(try ca.serverContext(for: "host0.example.test") === first,
                "a recently-used host must survive eviction")
    }

    @Test func mintedSerials_areExactly20Octets() throws {
        // Regression: a 21-octet serial (top random bit set → DER prepends 0x00)
        // violates RFC 5280 and makes Secure Transport reject the leaf with
        // -1015 "cannot decode raw data", silently breaking ~half of interception.
        // Mint many leaves so the ~50% case is exercised deterministically.
        //
        // Asserted as EXACTLY 20, not `<= 20`: the generator clears the top bit
        // (so DER never prepends 0x00 → never 21) *and* replaces a resulting zero
        // first byte (so the normalizer never strips a leading zero → never 19).
        // A loose bound would pass while either half regressed, quietly halving
        // the serial's entropy or drifting the encoded length.
        let ca = try CertificateAuthority.loadOrGenerate(store: InMemoryCAStore())
        for i in 0..<200 {
            let leaf = try ca.mintLeaf(for: "host\(i).example.test")
            let octets = leaf.serialNumber.bytes.count
            #expect(octets == 20, "leaf serial must be exactly 20 octets (RFC 5280 caps at 20), got \(octets)")
        }
    }

    @Test func theRootCASerial_isAlsoWithinTheLimit() throws {
        // The same generator mints the root's serial. Nothing pinned it, so a
        // change that fixed only the leaf path would look fully covered.
        let ca = try CertificateAuthority.loadOrGenerate(store: InMemoryCAStore())
        #expect(ca.certificate.serialNumber.bytes.count == 20)
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
        first.flush() // the write is queued; drain it before "relaunching"

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
    // The glob semantics themselves live in `GlobTests` (SharedModelsTests) with the
    // matcher — they were never about the SSL scope, which is exactly why the matcher
    // moved. What stays here is the scope's own decision.

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

/// `intercept_host` reports the connections it ended, and only ends them when the
/// write can actually take effect.
@Suite("interceptHost ends relayed tunnels", .serialized)
struct InterceptHostClosesTunnelsTests {
    @Test func aShadowedInterceptClosesNothing() async {
        // The host is in `include` but a wildcard `exclude` still relays it, so
        // reconnecting would land the client straight back in a relayed tunnel:
        // closing would cost it a reconnect and change nothing.
        let engine = ProxyEngine(persistFlows: false)
        defer { RelayedTunnelRegistry.shared.reset() }
        RelayedTunnelRegistry.shared.reset()
        let channel = EmbeddedChannel()
        let watch = ChannelCloseWatch(channel)
        RelayedTunnelRegistry.shared.register(host: "api.corp", port: 443, client: channel)

        await engine.setSSLScope(SSLScope(enabled: true, include: [], exclude: ["*.corp"]))
        let outcome = await engine.interceptHost("api.corp")

        #expect(outcome.effective == false)
        #expect(outcome.closedTunnels == 0)
        channel.embeddedEventLoop.run()
        #expect(watch.closed == false, "the connection would only be relayed again")
        _ = try? channel.finish()
    }

    @Test func anEffectiveInterceptReportsWhatItClosed() async {
        let engine = ProxyEngine(persistFlows: false)
        defer { RelayedTunnelRegistry.shared.reset() }
        RelayedTunnelRegistry.shared.reset()
        let channel = EmbeddedChannel()
        let watch = ChannelCloseWatch(channel)
        RelayedTunnelRegistry.shared.register(host: "api.example.test", port: 443, client: channel)

        await engine.setSSLScope(SSLScope(enabled: true, include: []))
        let outcome = await engine.interceptHost("api.example.test")

        #expect(outcome.effective)
        #expect(outcome.closedTunnels == 1,
                "a scope write that also ends a live connection has to say so")
        channel.embeddedEventLoop.run()
        #expect(watch.closed)
    }

    @Test func setSSLScopeClosesTunnelsTheNewScopeWouldDecrypt() async {
        let engine = ProxyEngine(persistFlows: false)
        defer { RelayedTunnelRegistry.shared.reset() }
        RelayedTunnelRegistry.shared.reset()
        let doomed = EmbeddedChannel(), spared = EmbeddedChannel()
        let doomedWatch = ChannelCloseWatch(doomed), sparedWatch = ChannelCloseWatch(spared)
        RelayedTunnelRegistry.shared.register(host: "api.example.test", port: 443, client: doomed)
        RelayedTunnelRegistry.shared.register(host: "other.example.test", port: 443, client: spared)

        await engine.setSSLScope(SSLScope(enabled: true, include: ["api.example.test"]))

        doomed.embeddedEventLoop.run()
        spared.embeddedEventLoop.run()
        #expect(doomedWatch.closed, "a host the new scope decrypts has to reconnect")
        #expect(sparedWatch.closed == false, "a host still unnamed stays on its tunnel")
        _ = try? doomed.finish()
        _ = try? spared.finish()
    }
}
