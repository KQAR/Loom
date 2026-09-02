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
    /// Move the listener to a different port, keeping the interface it is on. The
    /// SOCKS neighbour is decided here (`ListenPortRules.socksPort`), not by the
    /// engine — see the protocol requirement.
    public var setListenPort: @Sendable (_ port: Int) async throws -> ProxyStatus
    public var status: @Sendable () async -> ProxyStatus = {
        ProxyStatus(isRunning: false, port: 0, capturedCount: 0)
    }
    public var recentFlows: @Sendable (_ limit: Int) async -> [Flow] = { _ in [] }
    /// Filtered read — the scan happens inside the engine's store over everything
    /// retained, so a match older than the newest `limit` exchanges is still
    /// findable. The agent has had this since M6 (`get_recent_flows` filters);
    /// without it the human surface could only ever look at the newest N.
    public var recentFlowsMatching: @Sendable (_ query: FlowQuery, _ limit: Int) async -> [Flow] = { _, _ in [] }
    /// Sidebar counts over everything the engine retains, not over what this window
    /// holds. The window used to fold them itself, which made every badge a count of
    /// the newest 2000 exchanges against a store keeping 20 000.
    public var flowAggregates: @Sendable () async -> (aggregates: FlowAggregates, coversHistory: Bool) = {
        (FlowAggregates(), false)
    }
    /// One page of the capture, newest-first, resuming after a cursor — the read that
    /// reaches the durable store as well as the ring. The window seeds from this at
    /// launch: `recentFlows` sees only memory, so a relaunch used to open on whatever
    /// the ring had restored while the store held an order of magnitude more.
    public var flowPage: @Sendable (
        _ after: FlowCursor?, _ limit: Int, _ matching: FlowQuery
    ) async -> FlowPage = { _, _, _ in FlowPage(flows: []) }
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
    /// Hosts seen but not decrypted — what the console offers to intercept.
    public var tunneledHosts: @Sendable () async -> TunneledHostReport = { TunneledHostReport() }
    public var interceptHost: @Sendable (_ host: String) async -> InterceptOutcome = { _ in InterceptOutcome() }
    /// Stop decrypting one host — atomic inverse of `interceptHost`, so a console
    /// "Pass Through" can't clobber a concurrent agent edit of the scope.
    public var stopInterceptingHost: @Sendable (_ host: String) async -> StopInterceptOutcome = { _ in StopInterceptOutcome() }
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
    public var stopPhoneOnboarding: @Sendable () async throws -> Void
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

    // MARK: - Reverse-proxy endpoints
    //
    // Wired rather than left agent-only for the same reason as client certificates:
    // an endpoint is a *listening port on this machine* that an agent opened, and one
    // that outlives the debugging session keeps quietly capturing (and keeps a dev
    // server's config pointed at Loom). The human has to be able to see the list and
    // close one.

    public var reverseProxies: @Sendable () async -> [ReverseProxyStatus] = { [] }
    /// Validate, bind and persist. Throws when the upstream is unusable or the port
    /// can't be bound — it never returns an endpoint that isn't listening.
    public var createReverseProxy: @Sendable (_ endpoint: ReverseProxyEndpoint) async throws -> ReverseProxyStatus
    public var deleteReverseProxy: @Sendable (_ id: UUID) async throws -> Void
}

extension ProxyClient: DependencyKey {
    public static let liveValue: ProxyClient = {
        let engine = ProxyEngine.shared
        return ProxyClient(
            // The SOCKS listener rides one port above the HTTP proxy: the app always
            // wants it (a client that can only point at a SOCKS proxy is invisible
            // otherwise), while the engine defaults it off so an embedder isn't given
            // a second socket it never asked for.
            // `observeTunnels` is on for the app and off in the engine's own default,
            // which is the right split: an embedder gets content flows only, while the
            // app's request table is the operator's single list and has to show what it
            // is *not* reading. A pass-through otherwise records no flow at all, so the
            // carve-outs someone made are invisible on the surface they were made from.
            // The cost is stated rather than hidden: these are real flows, so a chatty
            // relayed origin spends the same `FlowLimits.persistedRows` budget as
            // content exchanges.
            start: { try await engine.start(port: $0, observeTunnels: true, socksPort: $0 + 1) },
            stop: { await engine.stop() },
            setListenPort: {
                try await engine.setListenPort($0, socksPort: ListenPortRules.socksPort(besides: $0))
            },
            status: { await engine.status() },
            recentFlows: { await engine.recentFlows(limit: $0) },
            recentFlowsMatching: { await engine.recentFlows(matching: $0, limit: $1) },
            flowAggregates: { await engine.flowAggregates() },
            flowPage: { await engine.flowPage(after: $0, limit: $1, matching: $2) },
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
            tunneledHosts: { await engine.tunneledHosts() },
            interceptHost: { await engine.interceptHost($0) },
            stopInterceptingHost: { await engine.stopInterceptingHost($0) },
            setRecording: { await engine.setRecording($0) },
            rulesState: { await engine.rulesState() },
            setRulesEnabled: { await engine.setRulesEnabled($0) },
            addRule: { try await engine.addRule($0) },
            updateRule: { try await engine.updateRule($0) },
            deleteRule: { try await engine.deleteRule(id: $0) },
            setGroupEnabled: { await engine.setGroupEnabled(group: $0, enabled: $1) },
            startPhoneOnboarding: { try await engine.startPhoneOnboarding() },
            stopPhoneOnboarding: { try await engine.stopPhoneOnboarding() },
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
            deleteClientCertificate: { try await engine.deleteClientCertificate(id: $0) },
            reverseProxies: { await engine.reverseProxies() },
            createReverseProxy: { try await engine.createReverseProxy($0) },
            deleteReverseProxy: { try await engine.deleteReverseProxy(id: $0) }
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
