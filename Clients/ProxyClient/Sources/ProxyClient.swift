import ComposableArchitecture
import Foundation
import LoomProxyCore
import LoomSharedModels

/// TCA-facing surface over the shared `ProxyEngine`. Reducers depend on this,
/// never on NIO directly, which keeps the feature layer testable and Swift-6 clean.
@DependencyClient
public struct ProxyClient: Sendable {
    public var start: @Sendable (_ port: Int) async throws -> Int
    public var stop: @Sendable () async -> Void
    public var status: @Sendable () async -> ProxyStatus = {
        ProxyStatus(isRunning: false, port: 0, capturedCount: 0)
    }
    public var recentFlows: @Sendable (_ limit: Int) async -> [Flow] = { _ in [] }
    /// Filtered read — the scan happens inside the engine's store over everything
    /// retained, so a match older than the newest `limit` exchanges is still
    /// findable. The agent has had this since M6 (`get_recent_flows` filters);
    /// without it the human surface could only ever look at the newest N.
    public var recentFlowsMatching: @Sendable (_ query: FlowQuery, _ limit: Int) async -> [Flow] = { _, _ in [] }
    public var flow: @Sendable (_ id: UUID) async -> Flow? = { _ in nil }
    /// Devices that have sent traffic through the proxy, with per-device counts.
    /// Flow-derived (unlike `connectedDeviceCountStream`, which is connection-derived).
    public var connectedDevices: @Sendable () async -> [DeviceSummary] = { [] }
    public var flowStream: @Sendable () async -> AsyncStream<Flow> = { AsyncStream { $0.finish() } }
    /// Fires when the capture is discarded by anyone — the window's own Clear or an
    /// agent's `clear_flows` — so the list never shows flows the store dropped.
    public var flowsClearedStream: @Sendable () async -> AsyncStream<Void> = { AsyncStream { $0.finish() } }
    public var replay: @Sendable (_ id: UUID, _ overrides: ReplayOverrides) async throws -> Flow
    public var clearFlows: @Sendable () async -> Void
    public var certificateStatus: @Sendable () async -> CertificateStatus = { .notGenerated }
    public var certificateDER: @Sendable () async -> Data? = { nil }
    /// Trust the CA for the current user (login keychain). `(ok, message)`.
    public var trustCertificate: @Sendable () async -> (ok: Bool, message: String?) = { (false, nil) }
    public var exportCACertificate: @Sendable () async throws -> URL
    public var sslScope: @Sendable () async -> SSLScope = { .disabled }
    public var setSSLScope: @Sendable (_ scope: SSLScope) async -> Void
    /// Pause/resume capture; forwarding is unaffected.
    public var setRecording: @Sendable (_ recording: Bool) async -> Void
    public var rulesState: @Sendable () async -> RulesState = { RulesState() }
    public var setRulesEnabled: @Sendable (_ enabled: Bool) async -> Void
    public var addRule: @Sendable (_ rule: TrafficRule) async throws -> Void
    public var updateRule: @Sendable (_ rule: TrafficRule) async throws -> Void
    public var deleteRule: @Sendable (_ id: UUID) async throws -> Void
    public var setGroupEnabled: @Sendable (_ group: String?, _ enabled: Bool) async -> Void
    /// Make the proxy LAN-reachable and publish the phone onboarding material
    /// (proxy address, CA download URL, QR code). Rebinds the proxy to `0.0.0.0`.
    public var startPhoneOnboarding: @Sendable () async throws -> PhoneOnboardingInfo
    /// Stop serving onboarding material and return the proxy to loopback-only.
    public var stopPhoneOnboarding: @Sendable () async -> Void
    /// Current onboarding info, or `nil` when inactive.
    public var phoneOnboardingInfo: @Sendable () async -> PhoneOnboardingInfo? = { nil }
    /// Recent write-action audit entries, newest first (the human Audit panel).
    public var recentAuditEntries: @Sendable (_ limit: Int) async -> [AuditEntry] = { _ in [] }
    /// Live stream of audit entries as write actions are recorded.
    public var auditStream: @Sendable () async -> AsyncStream<AuditEntry> = { AsyncStream { $0.finish() } }
    /// Clear the entire audit trail (ring + durable store).
    public var clearAudit: @Sendable () async -> Void = {}
    /// Live count of LAN devices connected to the proxy (excludes this Mac).
    public var connectedDeviceCountStream: @Sendable () async -> AsyncStream<Int> = { AsyncStream { $0.finish() } }

    // MARK: Breakpoints
    //
    // The supervision half of breakpoints. An armed breakpoint parks a *live client
    // connection* until someone resumes it, so an agent holding traffic that the
    // human's surface cannot see or release is the one write action where the
    // "human supervises" half of the contract genuinely breaks. These endpoints
    // exist so it can be built; see `ProxyCapability`.

    /// Arm a breakpoint. Throws `ProxyControlError.invalidBreakpoint` if malformed.
    public var armBreakpoint: @Sendable (_ breakpoint: Breakpoint) async throws -> Void
    /// Remove an armed breakpoint (exchanges it already holds still need a resume).
    public var disarmBreakpoint: @Sendable (_ id: UUID) async throws -> Void
    public var armedBreakpoints: @Sendable () async -> [Breakpoint] = { [] }
    /// Exchanges held right now, awaiting a resume decision.
    public var pendingBreakpoints: @Sendable () async -> [PendingBreakpoint] = { [] }
    /// Fires the moment an exchange is parked, so a surface showing held traffic
    /// doesn't have to poll. Unbuffered fan-out: subscribe before reading
    /// `pendingBreakpoints` if a hold must not be missed.
    public var pendingBreakpointStream: @Sendable () async -> AsyncStream<PendingBreakpoint> = { AsyncStream { $0.finish() } }
    /// Release a held exchange: apply `edit` and continue, or abort it with a 502.
    public var resumeBreakpoint: @Sendable (_ pendingID: UUID, _ abort: Bool, _ edit: BreakpointEdit) async throws -> Void

    // MARK: Mutual TLS
    //
    // Which client certificate Loom presents to a third party is exactly the kind of
    // write the human has to be able to see and revoke, so these are wired here from
    // the start rather than left agent-only. Summaries never carry the key or the
    // passphrase (see `ClientCertificateSummary`).

    public var clientCertificates: @Sendable () async -> [ClientCertificateSummary] = { [] }
    /// Add or replace by id; throws when the PKCS#12 bundle can't be opened.
    public var setClientCertificate: @Sendable (_ certificate: ClientCertificate) async throws -> Void
    public var deleteClientCertificate: @Sendable (_ id: UUID) async throws -> Void
}

extension ProxyClient: DependencyKey {
    public static let liveValue: ProxyClient = {
        let engine = ProxyEngine.shared
        return ProxyClient(
            // The SOCKS listener rides one port above the HTTP proxy: the app always
            // wants it (a client that can only point at a SOCKS proxy is invisible
            // otherwise), while the engine defaults it off so an embedder isn't given
            // a second socket it never asked for.
            start: { try await engine.start(port: $0, socksPort: $0 + 1) },
            stop: { await engine.stop() },
            status: { await engine.status() },
            recentFlows: { await engine.recentFlows(limit: $0) },
            recentFlowsMatching: { await engine.recentFlows(matching: $0, limit: $1) },
            flow: { await engine.flow(id: $0) },
            connectedDevices: { await engine.connectedDevices() },
            flowStream: { await engine.flowStream() },
            flowsClearedStream: { await engine.flowsClearedStream() },
            replay: { try await engine.replay(id: $0, overrides: $1) },
            clearFlows: { await engine.clearFlows() },
            certificateStatus: { await engine.certificateStatus() },
            certificateDER: { await engine.caCertificateDER() },
            trustCertificate: { await engine.trustCACertificate() },
            exportCACertificate: { try await engine.exportCACertificate() },
            sslScope: { await engine.sslScope() },
            setSSLScope: { await engine.setSSLScope($0) },
            setRecording: { await engine.setRecording($0) },
            rulesState: { await engine.rulesState() },
            setRulesEnabled: { await engine.setRulesEnabled($0) },
            addRule: { try await engine.addRule($0) },
            updateRule: { try await engine.updateRule($0) },
            deleteRule: { try await engine.deleteRule(id: $0) },
            setGroupEnabled: { await engine.setGroupEnabled(group: $0, enabled: $1) },
            startPhoneOnboarding: { try await engine.startPhoneOnboarding() },
            stopPhoneOnboarding: { await engine.stopPhoneOnboarding() },
            phoneOnboardingInfo: { await engine.phoneOnboardingInfo() },
            recentAuditEntries: { await engine.recentAuditEntries(limit: $0) },
            auditStream: { await engine.auditStream() },
            clearAudit: { await engine.clearAudit() },
            connectedDeviceCountStream: { await engine.connectedDeviceCountStream() },
            armBreakpoint: { try await engine.armBreakpoint($0) },
            disarmBreakpoint: { try await engine.disarmBreakpoint(id: $0) },
            armedBreakpoints: { await engine.armedBreakpoints() },
            pendingBreakpoints: { await engine.pendingBreakpoints() },
            pendingBreakpointStream: { await engine.pendingBreakpointStream() },
            resumeBreakpoint: { try await engine.resumeBreakpoint(pendingID: $0, abort: $1, edit: $2) },
            clientCertificates: { await engine.clientCertificates() },
            setClientCertificate: { try await engine.setClientCertificate($0) },
            deleteClientCertificate: { try await engine.deleteClientCertificate(id: $0) }
        )
    }()

    public static let testValue = ProxyClient()
}

public extension DependencyValues {
    var proxyClient: ProxyClient {
        get { self[ProxyClient.self] }
        set { self[ProxyClient.self] = newValue }
    }
}
