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
            // The approval switch lives in System Settings, so this is re-read on
            // every refresh rather than cached.
            $0.privilegedHelperClient.helperState = { .enabled }
            $0.privilegedHelperClient.helperFailureReason = { nil }
            $0.proxyClient.certificateStatus = { cert }
            $0.proxyClient.sslScope = { scope }
            $0.proxyClient.clientCertificates = { [] }
            $0.proxyClient.tunneledHosts = { TunneledHostReport() }
        }
        await store.send(.refresh)
        await store.receive(\.systemProxySnapshotChanged) {
            $0.systemProxyRouting = .loom
            $0.isSystemProxy = true
        }
        await store.receive(\.helperStateLoaded) { $0.helperState = .enabled }
        await store.receive(\.certificateStatusLoaded) { $0.certificateStatus = cert }
        await store.receive(\.sslScopeLoaded) {
            $0.sslScope = scope
            $0.sslEnabled = true
        }
        // The collapsed console row carries the unread count, so this is loaded even
        // when the scope editor is closed.
        await store.receive(\.tunneledHostsLoaded)
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
            $0.privilegedHelperClient.setSystemProxy = { _, _ in HelperOutcome(ok: true, message: nil) }
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

    @Test func test_toggleSystemProxy_partialSuccess_storesTheCaveat() async {
        // ok=true WITH a message is a partial success — the proxy landed but the
        // root-only QUIC work didn't (authorization declined). The caveat is
        // feedback about this action and must reach the panel, not be dropped
        // like the standing-claim text a clean success stores nothing for.
        let caveat = "Proxy is on, but QUIC (HTTP/3) stays unblocked without authorization — browser traffic may bypass capture."
        var initial = SetupFeature.State()
        initial.proxyRunning = true
        initial.isSystemProxy = false
        let store = TestStore(initialState: initial) {
            SetupFeature()
        } withDependencies: {
            $0.privilegedHelperClient.setSystemProxy = { _, _ in HelperOutcome(ok: true, message: caveat) }
            $0.privilegedHelperClient.systemProxySnapshot = {
                SystemProxySnapshot(
                    httpEnabled: true, httpHost: "127.0.0.1", httpPort: 9090,
                    httpsEnabled: true, httpsHost: "127.0.0.1", httpsPort: 9090
                )
            }
        }
        await store.send(.toggleSystemProxyTapped) {
            $0.isSystemProxy = true
            $0.systemProxyBusy = true
            $0.systemProxyMessage = "Setting system proxy…"
        }
        await store.receive(\.systemProxyResult) {
            $0.systemProxyBusy = false
            $0.systemProxyMessage = caveat   // kept: partial success, not silence
        }
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

    /// Turning HTTPS on decrypts **everything**.
    ///
    /// A whitelist default was built and rejected: it makes the common case "traffic
    /// happened and Loom read none of it", and fixing that costs a second run of the
    /// client because the first run's bytes are gone. The cost of this direction — a
    /// client with its own certificate store failing at the client — is handled case by
    /// case in the pass-through list, not by a guessed default.
    @Test func test_toggleSSL_enabling_decryptsEverything_thenReloadsCert() async {
        let cert = CertificateStatus(isGenerated: true, isTrusted: false)
        let store = TestStore(initialState: SetupFeature.State()) {
            SetupFeature()
        } withDependencies: {
            $0.proxyClient.setSSLScope = { _ in }
            $0.proxyClient.certificateStatus = { cert }
            $0.proxyClient.tunneledHosts = { TunneledHostReport() }
        }
        await store.send(.toggleSSLTapped) {
            $0.sslEnabled = true
            $0.sslScope = SSLScope(enabled: true, include: ["*"])
        }
        await store.receive(\.certificateStatusLoaded) {
            $0.certificateStatus = cert
        }
        await store.receive(\.tunneledHostsLoaded)
    }

    // MARK: SSL scope editing + tunnelled hosts

    /// The one-click path from "Loom showed me nothing" to "Loom is decrypting it".
    @Test func test_interceptHostTapped_reReadsScopeAndList_ratherThanPredictingThem() async {
        let intercepted = SSLScope(enabled: true, include: ["api.example.com"])
        let store = TestStore(initialState: SetupFeature.State()) {
            SetupFeature()
        } withDependencies: {
            $0.proxyClient.interceptHost = { _ in
                var outcome = InterceptOutcome()
                outcome.enabledInterception = true
                return outcome
            }
            // Re-read, not predicted: an agent may have edited the scope in between.
            $0.proxyClient.sslScope = { intercepted }
            $0.proxyClient.tunneledHosts = { TunneledHostReport() }
        }
        await store.send(.interceptHostTapped("api.example.com"))
        await store.receive(\.interceptFinished) {
            $0.sslScopeMessage = "Decrypting api.example.com. HTTPS interception is now on. Re-run your client — connections already made are gone."
        }
        await store.receive(\.sslScopeLoaded) {
            $0.sslScope = intercepted
            $0.sslEnabled = true
        }
        await store.receive(\.tunneledHostsLoaded)
    }

    /// A write that lands and still doesn't decrypt anything is the failure this
    /// surface exists to remove, so the message says so instead of reporting success.
    @Test func test_interceptFinished_shadowedByExclude_saysTheHostIsStillPassedThrough() async {
        let store = TestStore(initialState: SetupFeature.State()) {
            SetupFeature()
        } withDependencies: {
            $0.proxyClient.sslScope = { SSLScope(enabled: true, include: ["api.example.com"], exclude: ["*.example.com"]) }
            $0.proxyClient.tunneledHosts = { TunneledHostReport() }
        }
        var outcome = InterceptOutcome()
        outcome.shadowedByExclude = "*.example.com"
        await store.send(.interceptFinished(host: "api.example.com", outcome: outcome)) {
            $0.sslScopeMessage = "api.example.com is included but still passed through — “*.example.com” excludes it."
        }
        await store.receive(\.sslScopeLoaded) {
            $0.sslScope = SSLScope(enabled: true, include: ["api.example.com"], exclude: ["*.example.com"])
            $0.sslEnabled = true
        }
        await store.receive(\.tunneledHostsLoaded)
    }

    /// "Never decrypt this" — how an origin leaves the to-do list without being read.
    @Test func test_excludeHostTapped_movesTheHostToTheExcludeList() async {
        let start = SSLScope(enabled: true, include: ["dl.google.com"])
        let expected = SSLScope(enabled: true, include: [], exclude: ["dl.google.com"])
        var state = SetupFeature.State()
        state.sslScope = start
        state.sslEnabled = true
        let store = TestStore(initialState: state) {
            SetupFeature()
        } withDependencies: {
            $0.proxyClient.setSSLScope = { _ in }
            $0.proxyClient.sslScope = { expected }
            $0.proxyClient.tunneledHosts = { TunneledHostReport() }
        }
        await store.send(.excludeHostTapped("dl.google.com")) {
            $0.sslScope = expected
            $0.sslScopeMessage = "dl.google.com will be passed through untouched."
        }
        await store.receive(\.sslScopeLoaded)
        await store.receive(\.tunneledHostsLoaded)
    }

    /// The glob lists collapse by default and the tunnelled list does not, because
    /// they grow in opposite directions — but collapsed must never mean unreachable:
    /// removing an include entry is the only way to stop decrypting a host, and the
    /// only place an agent's `intercept_host` becomes visible to the human.
    @Test func test_globListsAreCollapsedByDefault_andToggleWithoutHittingTheEngine() async {
        let store = TestStore(initialState: SetupFeature.State()) { SetupFeature() }
        #expect(store.state.sslGlobsExpanded == false)
        await store.send(.sslGlobsExpandTapped) { $0.sslGlobsExpanded = true }
        await store.send(.sslGlobsExpandTapped) { $0.sslGlobsExpanded = false }
    }

    /// The card's one text field carves a host *out*, because with the default scope
    /// covering everything an include entry is a no-op. It also drops a stale include
    /// for the same host, or the two lists would disagree about it.
    @Test func test_addExcludeGlob_carvesTheHostOut_andDropsItsIncludeEntry() async {
        let expected = SSLScope(enabled: true, include: ["*"], exclude: ["artifactory.corp.example"])
        var state = SetupFeature.State()
        state.sslEnabled = true
        state.sslScope = SSLScope(enabled: true, include: ["*", "artifactory.corp.example"])
        state.sslScopeDraft = "  artifactory.corp.example  "
        let store = TestStore(initialState: state) {
            SetupFeature()
        } withDependencies: {
            $0.proxyClient.setSSLScope = { _ in }
            $0.proxyClient.sslScope = { expected }
            $0.proxyClient.tunneledHosts = { TunneledHostReport() }
        }
        await store.send(.addExcludeGlobTapped) {
            $0.sslScopeDraft = ""
            $0.sslScope = expected
        }
        await store.receive(\.sslScopeLoaded)
        await store.receive(\.tunneledHostsLoaded)
    }

    /// Removing a pass-through is how a host someone carved out becomes readable again.
    @Test func test_removeExcludeGlob_startsDecryptingTheHostAgain() async {
        let expected = SSLScope(enabled: true, include: ["*"], exclude: [])
        var state = SetupFeature.State()
        state.sslEnabled = true
        state.sslScope = SSLScope(enabled: true, include: ["*"], exclude: ["pypi.org"])
        let store = TestStore(initialState: state) {
            SetupFeature()
        } withDependencies: {
            $0.proxyClient.setSSLScope = { _ in }
            $0.proxyClient.sslScope = { expected }
            $0.proxyClient.tunneledHosts = { TunneledHostReport() }
        }
        await store.send(.removeExcludeGlobTapped("pypi.org")) { $0.sslScope = expected }
        await store.receive(\.sslScopeLoaded)
        await store.receive(\.tunneledHostsLoaded)
    }

    /// The collapsed row's count, and the orange tint, deliberately ignore an
    /// `excluded` pass-through: under a scope covering everything that is the
    /// configuration working, and counting it would teach the human to ignore the number.
    @Test func test_unexpectedlyUnreadHosts_ignoresDeliberatePassThroughs() {
        var state = SetupFeature.State()
        state.tunneledHosts = [
            TunneledHost(host: "pypi.org", port: 443, firstSeen: .distantPast, lastSeen: .distantPast, reason: .excluded),
            TunneledHost(host: "ssh.example.com", port: 22, firstSeen: .distantPast, lastSeen: .distantPast, reason: .notTLSOrHTTP),
            TunneledHost(host: "api.example.com", port: 443, firstSeen: .distantPast, lastSeen: .distantPast, reason: .interceptionDisabled),
        ]
        #expect(state.unexpectedlyUnreadHosts.map(\.host) == ["api.example.com"])
        // Still offered a Decrypt button, though — an exclusion is reversible.
        #expect(state.interceptableTunneledHosts.map(\.host) == ["pypi.org", "api.example.com"])
    }

    /// Only the interceptable entries drive the console's "unread" count and its
    /// Decrypt buttons — an SSH tunnel does not become readable by being listed.
    @Test func test_interceptableTunneledHosts_excludesWhatNoScopeChangeFixes() {
        var state = SetupFeature.State()
        state.tunneledHosts = [
            TunneledHost(host: "api.example.com", port: 443, firstSeen: .distantPast, lastSeen: .distantPast, reason: .notInScope),
            TunneledHost(host: "ssh.example.com", port: 22, firstSeen: .distantPast, lastSeen: .distantPast, reason: .notTLSOrHTTP),
        ]
        #expect(state.interceptableTunneledHosts.map(\.host) == ["api.example.com"])
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
    // MARK: Privileged helper

    /// A first install lands on `requiresApproval` — success, not failure — and the
    /// human has to flip a switch in another app, so the row says where and opens it.
    @Test func helperInstall_landsOnApprovalAndOpensSettings() async {
        let opened = LockIsolated(false)
        let store = TestStore(initialState: SetupFeature.State()) {
            SetupFeature()
        } withDependencies: {
            $0.privilegedHelperClient.installHelper = { (.requiresApproval, nil) }
            $0.privilegedHelperClient.openHelperApproval = { opened.setValue(true) }
        }
        await store.send(.helperRowTapped) {
            $0.helperBusy = true
            $0.helperMessage = "Installing helper…"
        }
        await store.receive(\.helperActionFinished) {
            $0.helperBusy = false
            $0.helperState = .requiresApproval
            $0.helperMessage = "Allow “Loom” in Login Items to finish."
        }
        #expect(opened.value, "there is no API to flip that switch — the least we do is open it")
    }

    /// Already awaiting approval: tapping again must NOT re-register (that changes
    /// nothing and would re-run the whole dance) — just take the human to the switch.
    @Test func helperAwaitingApproval_onlyOpensSettings() async {
        let opened = LockIsolated(false)
        var state = SetupFeature.State()
        state.helperState = .requiresApproval
        let store = TestStore(initialState: state) {
            SetupFeature()
        } withDependencies: {
            $0.privilegedHelperClient.openHelperApproval = { opened.setValue(true) }
            // installHelper deliberately left unimplemented: reaching it is the failure.
        }
        await store.send(.helperRowTapped)
        #expect(opened.value)
    }

    /// `unresponsive` is the state an app update leaves behind — launchd holding a job
    /// that names the old binary while `SMAppService` still reports it enabled. The
    /// repair is a re-registration, so the row runs the install path and says so.
    @Test func helperUnresponsive_repairsByReinstalling() async {
        var state = SetupFeature.State()
        state.helperState = .unresponsive
        let store = TestStore(initialState: state) {
            SetupFeature()
        } withDependencies: {
            $0.privilegedHelperClient.installHelper = { (.enabled, nil) }
        }
        await store.send(.helperRowTapped) {
            $0.helperBusy = true
            $0.helperMessage = "Repairing helper…"
        }
        await store.receive(\.helperActionFinished) {
            $0.helperBusy = false
            $0.helperState = .enabled
            $0.helperMessage = nil
        }
    }

    /// Removing it is not a failure state: the toggle keeps working, it just asks for
    /// a password again — so no error text is left on the row.
    @Test func helperEnabled_tapRemovesIt() async {
        var state = SetupFeature.State()
        state.helperState = .enabled
        let store = TestStore(initialState: state) {
            SetupFeature()
        } withDependencies: {
            $0.privilegedHelperClient.uninstallHelper = { (.notInstalled, nil) }
        }
        await store.send(.helperRowTapped) {
            $0.helperBusy = true
            $0.helperMessage = "Removing helper…"
        }
        await store.receive(\.helperActionFinished) {
            $0.helperBusy = false
            $0.helperState = .notInstalled
            $0.helperMessage = nil
        }
    }
}
