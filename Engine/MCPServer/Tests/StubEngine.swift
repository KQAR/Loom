import Foundation
import SharedModels

/// An in-memory `ProxyControlling` for exercising `MCPToolExecutor` without NIO.
/// Records the last write so tests can assert the executor forwarded correctly,
/// and holds a mutable rule set so the rule CRUD tools round-trip.
final class StubEngine: ProxyControlling, @unchecked Sendable {
    var flows: [Flow] = []
    var rules = RulesState()
    var scope = SSLScope.disabled
    var cert = CertificateStatus.notGenerated
    var proxyStatus = ProxyStatus(isRunning: true, port: 9090, capturedCount: 0)
    var recording = true
    var devices: [DeviceSummary] = []

    // Spies
    private(set) var lastReplay: (id: UUID, overrides: ReplayOverrides)?
    private(set) var lastSSLScope: SSLScope?
    private(set) var setRulesEnabledCalls: [Bool] = []
    private(set) var addedRules: [TrafficRule] = []
    private(set) var deletedRuleIDs: [UUID] = []
    var replayResult: Flow?
    var replayError: Error?

    // FlowProviding
    func status() async -> ProxyStatus { proxyStatus }
    func recentFlows(limit: Int) async -> [Flow] { Array(flows.prefix(limit)) }
    func recentFlowsForExport(limit: Int) async -> [Flow] { Array(flows.prefix(limit)) }
    func flow(id: UUID) async -> Flow? { flows.first { $0.id == id } }
    func flowStream() async -> AsyncStream<Flow> { AsyncStream { $0.finish() } }
    func connectedDevices() async -> [DeviceSummary] { devices }

    // FlowReplaying
    func replay(id: UUID, overrides: ReplayOverrides) async throws -> Flow {
        lastReplay = (id, overrides)
        if let replayError { throw replayError }
        if let replayResult { return replayResult }
        return Flow(id: UUID(), request: CapturedRequest(method: "GET", url: "https://x/", headers: []),
                    startedAt: Date(), outcome: .completed(CapturedResponse(statusCode: 200, headers: []), at: Date()),
                    replayedFrom: id)
    }

    // TLSInterceptControlling
    func certificateStatus() async -> CertificateStatus { cert }
    func exportCACertificate() async throws -> URL { URL(fileURLWithPath: "/tmp/loom-ca.pem") }
    func sslScope() async -> SSLScope { scope }
    func setSSLScope(_ scope: SSLScope) async { self.scope = scope; lastSSLScope = scope }

    // CaptureControlling
    func setRecording(_ recording: Bool) async { self.recording = recording }

    // RulesControlling
    func rulesState() async -> RulesState { rules }
    func setRulesEnabled(_ enabled: Bool) async { rules.enabled = enabled; setRulesEnabledCalls.append(enabled) }
    func addRule(_ rule: TrafficRule) async throws {
        if let reason = rule.validationError() { throw ProxyControlError.invalidRule(reason) }
        addedRules.append(rule)
        rules.rules.append(rule)
    }
    func updateRule(_ rule: TrafficRule) async throws {
        guard let i = rules.rules.firstIndex(where: { $0.id == rule.id }) else {
            throw ProxyControlError.ruleNotFound(rule.id)
        }
        rules.rules[i] = rule
    }
    func deleteRule(id: UUID) async throws {
        guard rules.rules.contains(where: { $0.id == id }) else { throw ProxyControlError.ruleNotFound(id) }
        deletedRuleIDs.append(id)
        rules.rules.removeAll { $0.id == id }
    }
    func setRules(_ rules: [TrafficRule]) async throws {
        for rule in rules where rule.validationError() != nil {
            throw ProxyControlError.invalidRule(rule.validationError()!)
        }
        self.rules.rules = rules
    }
    func setGroupEnabled(group: String?, enabled: Bool) async {
        for i in rules.rules.indices where rules.rules[i].group == group { rules.rules[i].isEnabled = enabled }
    }

    // BreakpointControlling
    var armed: [Breakpoint] = []
    var pending: [PendingBreakpoint] = []
    private(set) var resumeCalls: [(id: UUID, abort: Bool, edit: BreakpointEdit)] = []
    func armBreakpoint(_ breakpoint: Breakpoint) async throws {
        if let reason = breakpoint.validationError { throw ProxyControlError.invalidBreakpoint(reason) }
        armed.append(breakpoint)
    }
    func disarmBreakpoint(id: UUID) async throws {
        guard armed.contains(where: { $0.id == id }) else { throw ProxyControlError.breakpointNotFound(id) }
        armed.removeAll { $0.id == id }
    }
    func armedBreakpoints() async -> [Breakpoint] { armed }
    func pendingBreakpoints() async -> [PendingBreakpoint] { pending }
    func resumeBreakpoint(pendingID: UUID, abort: Bool, edit: BreakpointEdit) async throws {
        guard pending.contains(where: { $0.id == pendingID }) else {
            throw ProxyControlError.pendingBreakpointNotFound(pendingID)
        }
        resumeCalls.append((pendingID, abort, edit))
        pending.removeAll { $0.id == pendingID }
    }
}
