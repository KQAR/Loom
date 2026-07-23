import ComposableArchitecture
import PrivilegedHelperClient
import SharedModels
import XCTest

@testable import AppFeature

/// `TestStore` coverage for the extracted `SetupFeature`: the boot refresh, the
/// optimistic system-proxy toggle (with revert on failure), the SSL toggle's
/// intercept-all default, and the CA trust/recheck/export flows.
@MainActor
final class SetupFeatureTests: XCTestCase {
    private struct StubError: Error {}

    // MARK: Refresh (boot re-sync)

    func test_refresh_loadsSystemProxyCertAndScope() async {
        let cert = CertificateStatus(isGenerated: true, isTrusted: false, commonName: "Loom Root")
        let scope = SSLScope(enabled: true, include: ["*"])
        let store = TestStore(initialState: SetupFeature.State()) {
            SetupFeature()
        } withDependencies: {
            $0.privilegedHelperClient.isSystemProxyActive = { _ in true }
            $0.proxyClient.certificateStatus = { cert }
            $0.proxyClient.sslScope = { scope }
        }
        await store.send(.refresh)
        await store.receive(\.systemProxyStateLoaded) { $0.isSystemProxy = true }
        await store.receive(\.certificateStatusLoaded) { $0.certificateStatus = cert }
        await store.receive(\.sslScopeLoaded) {
            $0.sslScope = scope
            $0.sslEnabled = true
        }
    }

    // MARK: System proxy

    func test_toggleSystemProxy_blockedWhenProxyStoppedButProxyOn() async {
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

    func test_toggleSystemProxy_enabling_optimistic_thenResultOK() async {
        var initial = SetupFeature.State()
        initial.proxyRunning = true
        initial.isSystemProxy = false
        let store = TestStore(initialState: initial) {
            SetupFeature()
        } withDependencies: {
            $0.privilegedHelperClient.setSystemProxy = { _, _ in HelperOutcome(ok: true, message: "") }
        }
        await store.send(.toggleSystemProxyTapped) {
            $0.isSystemProxy = true            // optimistic
            $0.systemProxyBusy = true
            $0.systemProxyMessage = "Setting system proxy…"
        }
        await store.receive(\.systemProxyResult) {
            $0.systemProxyBusy = false
            $0.systemProxyMessage = "On — QUIC blocked so browser (HTTP/3) traffic is captured. Restored when Loom quits."
        }
    }

    func test_toggleSystemProxy_result_failure_revertsOptimisticToggle() async {
        var initial = SetupFeature.State()
        initial.proxyRunning = true
        initial.isSystemProxy = false
        let store = TestStore(initialState: initial) {
            SetupFeature()
        } withDependencies: {
            $0.privilegedHelperClient.setSystemProxy = { _, _ in HelperOutcome(ok: false, message: "networksetup failed") }
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
    }

    // MARK: SSL interception

    func test_toggleSSL_enabling_defaultsToInterceptAll_thenReloadsCert() async {
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

    func test_sslScopeLoaded_syncsEnabledFlag() async {
        let store = TestStore(initialState: SetupFeature.State()) { SetupFeature() }
        let scope = SSLScope(enabled: true, include: ["api.example.com"])
        await store.send(.sslScopeLoaded(scope)) {
            $0.sslScope = scope
            $0.sslEnabled = true
        }
    }

    // MARK: Root-CA trust

    func test_installAndTrustCA_started_loaded_finished() async {
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

    func test_recheckCert_reloadsStatus_clearsMessage() async {
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

    func test_exportCA_failure_yieldsNilWithoutSideEffect() async {
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
