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
    public var flow: @Sendable (_ id: UUID) async -> Flow? = { _ in nil }
    public var flowStream: @Sendable () async -> AsyncStream<Flow> = { AsyncStream { $0.finish() } }
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
}

extension ProxyClient: DependencyKey {
    public static let liveValue: ProxyClient = {
        let engine = ProxyEngine.shared
        return ProxyClient(
            start: { try await engine.start(port: $0) },
            stop: { await engine.stop() },
            status: { await engine.status() },
            recentFlows: { await engine.recentFlows(limit: $0) },
            flow: { await engine.flow(id: $0) },
            flowStream: { await engine.flowStream() },
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
            phoneOnboardingInfo: { await engine.phoneOnboardingInfo() }
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
