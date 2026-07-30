import ComposableArchitecture
import Foundation
import PrivilegedHelperClient
import LoomSharedModels
import Testing

@testable import AppFeature

/// `TestStore` coverage for the extracted `SetupFeature`: the boot refresh, the
/// optimistic system-proxy toggle (with revert on failure), the SSL toggle's
/// intercept-all default, and the CA trust/recheck/export flows.
@MainActor
@Suite struct SetupFeatureTests {
    private struct StubError: Error {}

    // MARK: Refresh (boot re-sync)

    @Test func test_refresh_loadsSystemProxyCertAndScope() async {
        let cert = CertificateStatus(isGenerated: true, isTrusted: false, commonName: "Loom Root")
        let scope = SSLScope(enabled: true, include: ["*"])
        let store = TestStore(initialState: SetupFeature.State()) {
            SetupFeature()
        } withDependencies: {
            // `refresh` reads the effective settings rather than a bare boolean, so the
            // panel can distinguish "off" from "another proxy app owns it".
            $0.privilegedHelperClient.systemProxySnapshot = {
                SystemProxySnapshot(
                    httpEnabled: true, httpHost: "127.0.0.1", httpPort: 9090,
                    httpsEnabled: true, httpsHost: "127.0.0.1", httpsPort: 9090
                )
            }
            $0.proxyClient.certificateStatus = { cert }
            $0.proxyClient.sslScope = { scope }
            $0.proxyClient.clientCertificates = { [] }
        }
        await store.send(.refresh)
        await store.receive(\.systemProxySnapshotChanged) {
            $0.systemProxyRouting = .loom
            $0.isSystemProxy = true
        }
        await store.receive(\.certificateStatusLoaded) { $0.certificateStatus = cert }
        await store.receive(\.sslScopeLoaded) {
            $0.sslScope = scope
            $0.sslEnabled = true
        }
        // Re-read on every appearance: the other writer is an agent, so an identity
        // can appear without the human having done anything.
        await store.receive(\.clientCertificatesLoaded)
    }

    // MARK: Mutual TLS (client certificates)

    @Test func test_expandingClientCerts_reloadsTheList() async {
        let summary = ClientCertificateSummary(
            id: UUID(0), hostPattern: "api.corp.example", label: "Corp", isEnabled: true,
            subject: "CN=client", notAfter: Date(timeIntervalSince1970: 4_000_000_000)
        )
        let store = TestStore(initialState: SetupFeature.State()) {
            SetupFeature()
        } withDependencies: {
            $0.proxyClient.clientCertificates = { [summary] }
        }

        await store.send(.clientCertsExpandTapped) { $0.clientCertsExpanded = true }
        await store.receive(\.clientCertificatesLoaded) { $0.clientCertificates = [summary] }

        // Collapsing is just UI — no reason to hit the engine again.
        await store.send(.clientCertsExpandTapped) { $0.clientCertsExpanded = false }
    }

    @Test func test_addClientCertificate_readsTheFileAndStoresItsBytes() async throws {
        // The view hands over a URL, not bytes: reading key material belongs in the
        // effect, not on the main thread inside a form's @State.
        let bundle = Data("pretend-pkcs12".utf8)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("loom-setup-test-\(UUID()).p12")
        try bundle.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let saved = LockIsolated<ClientCertificate?>(nil)
        let store = TestStore(initialState: SetupFeature.State()) {
            SetupFeature()
        } withDependencies: {
            $0.proxyClient.setClientCertificate = { certificate in
                saved.setValue(certificate)
            }
            $0.proxyClient.clientCertificates = { [] }
        }

        await store.send(.addClientCertificate(
            url: url, hostPattern: "api.corp.example", passphrase: "s3cret", label: "Corp"
        )) {
            $0.clientCertBusy = true
        }
        await store.receive(\.clientCertificatesLoaded)
        await store.receive(\.clientCertFinished) { $0.clientCertBusy = false }

        let certificate = try #require(saved.value)
        #expect(certificate.pkcs12 == bundle)
        #expect(certificate.hostPattern == "api.corp.example")
        #expect(certificate.passphrase == "s3cret")
        #expect(certificate.label == "Corp")
    }

    @Test func test_addClientCertificate_relaysTheEnginesMessageVerbatim() async throws {
        // The engine validates the bundle on the way in, and its message names what
        // the operator can fix (wrong passphrase / not a .p12). Replacing it with a
        // generic failure would throw that away.
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("loom-setup-test-\(UUID()).p12")
        try Data("pretend".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let store = TestStore(initialState: SetupFeature.State()) {
            SetupFeature()
        } withDependencies: {
            $0.proxyClient.setClientCertificate = { _ in
                throw ProxyControlError.invalidClientCertificate("wrong passphrase")
            }
        }

        await store.send(.addClientCertificate(url: url, hostPattern: "a.test", passphrase: "", label: "")) {
            $0.clientCertBusy = true
        }
        await store.receive(\.clientCertFinished) {
            $0.clientCertBusy = false
            $0.clientCertMessage = "invalid client certificate: wrong passphrase"
        }
        // The list is not reloaded on failure: nothing changed, and a reload would
        // clear the message's context.
    }

    @Test func test_addClientCertificate_unreadableFileStillReportsRatherThanFailingSilently() async {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("loom-missing-\(UUID()).p12")
        let store = TestStore(initialState: SetupFeature.State()) { SetupFeature() }
        // Non-exhaustive on purpose: the exact wording comes from Foundation and is
        // localized. What must hold is that *something* reaches the operator instead
        // of the add quietly doing nothing.
        store.exhaustivity = .off

        await store.send(.addClientCertificate(url: missing, hostPattern: "a.test", passphrase: "", label: ""))
        await store.receive(\.clientCertFinished)
        #expect(store.state.clientCertBusy == false)
        #expect(store.state.clientCertMessage?.isEmpty == false)
    }

    @Test func test_deleteClientCertificate_reloadsTheList() async {
        let deleted = LockIsolated<UUID?>(nil)
        var initial = SetupFeature.State()
        initial.clientCertificates = [ClientCertificateSummary(
            id: UUID(1), hostPattern: "a.test", label: "a.test", isEnabled: true
        )]
        let store = TestStore(initialState: initial) {
            SetupFeature()
        } withDependencies: {
            $0.proxyClient.deleteClientCertificate = { deleted.setValue($0) }
            $0.proxyClient.clientCertificates = { [] }
        }

        await store.send(.deleteClientCertificateTapped(id: UUID(1))) { $0.clientCertBusy = true }
        await store.receive(\.clientCertificatesLoaded) { $0.clientCertificates = [] }
        await store.receive(\.clientCertFinished) { $0.clientCertBusy = false }
        #expect(deleted.value == UUID(1))
    }

    @Test func test_brokenClientCertificates_countsExpiredAndUnreadable() {
        // The row's "needs attention" count. Expired and unreadable both fail a
        // handshake exactly like having no identity, so they're one category.
        var state = SetupFeature.State()
        state.clientCertificates = [
            ClientCertificateSummary(
                id: UUID(0), hostPattern: "good.test", label: "good", isEnabled: true,
                subject: "CN=c", notAfter: Date(timeIntervalSince1970: 4_000_000_000)
            ),
            ClientCertificateSummary(
                id: UUID(1), hostPattern: "expired.test", label: "expired", isEnabled: true,
                subject: "CN=c", notAfter: Date(timeIntervalSince1970: 1)
            ),
            ClientCertificateSummary(
                id: UUID(2), hostPattern: "broken.test", label: "broken", isEnabled: true,
                problem: "could not read the PKCS#12 bundle"
            ),
        ]
        #expect(state.brokenClientCertificates.map(\.hostPattern) == ["expired.test", "broken.test"])
    }

    // MARK: System proxy

    @Test func test_toggleSystemProxy_blockedWhenProxyStoppedButProxyOn() async {
        // Pre-existing guard: can't change while the system proxy is on but the
        // Loom proxy is stopped — the human must start the proxy first.
        var initial = SetupFeature.State()
        initial.isSystemProxy = true
        initial.proxyRunning = false
        let store = TestStore(initialState: initial) { SetupFeature() }
        await store.send(.toggleSystemProxyTapped) {
            $0.systemProxyMessage = "Start the proxy first."
        }
    }

    @Test func test_toggleSystemProxy_enabling_optimistic_thenResultOK() async {
        var initial = SetupFeature.State()
        initial.proxyRunning = true
        initial.isSystemProxy = false
        let store = TestStore(initialState: initial) {
            SetupFeature()
        } withDependencies: {
            $0.privilegedHelperClient.setSystemProxy = { _, _ in HelperOutcome(ok: true, message: "") }
            $0.privilegedHelperClient.systemProxySnapshot = {
                SystemProxySnapshot(
                    httpEnabled: true, httpHost: "127.0.0.1", httpPort: 9090,
                    httpsEnabled: true, httpsHost: "127.0.0.1", httpsPort: 9090
                )
            }
        }
        await store.send(.toggleSystemProxyTapped) {
            $0.isSystemProxy = true            // optimistic
            $0.systemProxyBusy = true
            $0.systemProxyMessage = "Setting system proxy…"
        }
        await store.receive(\.systemProxyResult) {
            $0.systemProxyBusy = false
            // No message: the "QUIC is blocked" note describes current routing, so the
            // panel derives it. See `aSuccessfulEnableStoresNoStandingClaim`.
            $0.systemProxyMessage = nil
        }
        // Snapshots are ignored while busy, so the result re-reads once to confirm the
        // optimistic value against what macOS actually has.
        await store.receive(\.systemProxySnapshotChanged) { $0.systemProxyRouting = .loom }
    }

    @Test func test_toggleSystemProxy_result_failure_revertsOptimisticToggle() async {
        var initial = SetupFeature.State()
        initial.proxyRunning = true
        initial.isSystemProxy = false
        let store = TestStore(initialState: initial) {
            SetupFeature()
        } withDependencies: {
            $0.privilegedHelperClient.setSystemProxy = { _, _ in HelperOutcome(ok: false, message: "networksetup failed") }
            $0.privilegedHelperClient.systemProxySnapshot = { .off }
        }
        await store.send(.toggleSystemProxyTapped) {
            $0.isSystemProxy = true
            $0.systemProxyBusy = true
            $0.systemProxyMessage = "Setting system proxy…"
        }
        await store.receive(\.systemProxyResult) {
            $0.systemProxyBusy = false
            $0.isSystemProxy = false           // reverted
            $0.systemProxyMessage = "networksetup failed"
        }
        // Already `.off`, so nothing changes — but the read must still happen, or a
        // half-applied write would leave the row asserting the optimistic value.
        await store.receive(\.systemProxySnapshotChanged)
    }

    // MARK: SSL interception

    @Test func test_toggleSSL_enabling_defaultsToInterceptAll_thenReloadsCert() async {
        let cert = CertificateStatus(isGenerated: true, isTrusted: false)
        let store = TestStore(initialState: SetupFeature.State()) {
            SetupFeature()
        } withDependencies: {
            $0.proxyClient.setSSLScope = { _ in }
            $0.proxyClient.certificateStatus = { cert }
        }
        await store.send(.toggleSSLTapped) {
            $0.sslEnabled = true
            $0.sslScope = SSLScope(enabled: true, include: ["*"]) // first-on default
        }
        await store.receive(\.certificateStatusLoaded) {
            $0.certificateStatus = cert
        }
    }

    @Test func test_sslScopeLoaded_syncsEnabledFlag() async {
        let store = TestStore(initialState: SetupFeature.State()) { SetupFeature() }
        let scope = SSLScope(enabled: true, include: ["api.example.com"])
        await store.send(.sslScopeLoaded(scope)) {
            $0.sslScope = scope
            $0.sslEnabled = true
        }
    }

    // MARK: Root-CA trust

    @Test func test_installAndTrustCA_started_loaded_finished() async {
        let trusted = CertificateStatus(isGenerated: true, isTrusted: true)
        let store = TestStore(initialState: SetupFeature.State()) {
            SetupFeature()
        } withDependencies: {
            $0.proxyClient.trustCertificate = { (true, nil) }
            $0.proxyClient.certificateStatus = { trusted }
        }
        await store.send(.installAndTrustCATapped)
        await store.receive(\.certActionStarted) {
            $0.certBusy = true
            $0.certActionMessage = "Requesting trust — enter your login password…"
        }
        await store.receive(\.certificateStatusLoaded) {
            $0.certificateStatus = trusted
        }
        await store.receive(\.certActionFinished) {
            $0.certBusy = false
            $0.certActionMessage = "Trusted. HTTPS interception is ready."
        }
    }

    @Test func test_recheckCert_reloadsStatus_clearsMessage() async {
        let cert = CertificateStatus(isGenerated: true, isTrusted: false)
        let store = TestStore(initialState: SetupFeature.State()) {
            SetupFeature()
        } withDependencies: {
            $0.proxyClient.certificateStatus = { cert }
        }
        await store.send(.recheckCertTapped)
        await store.receive(\.certActionStarted) {
            $0.certBusy = true
            $0.certActionMessage = "Re-checking trust…"
        }
        await store.receive(\.certificateStatusLoaded) {
            $0.certificateStatus = cert
        }
        await store.receive(\.certActionFinished) {
            $0.certBusy = false
            $0.certActionMessage = nil
        }
    }

    @Test func test_exportCA_failure_yieldsNilWithoutSideEffect() async {
        // Export failing → caExported(nil) → no state change and no Finder reveal.
        let store = TestStore(initialState: SetupFeature.State()) {
            SetupFeature()
        } withDependencies: {
            $0.proxyClient.exportCACertificate = { throw StubError() }
        }
        await store.send(.exportCATapped)
        await store.receive(\.caExported)
    }
}
