import Foundation
import LoomSharedModels

/// An in-memory `ProxyControlling` for exercising `MCPToolExecutor` without NIO.
/// Records the last write so tests can assert the executor forwarded correctly,
/// and holds a mutable rule set so the rule CRUD tools round-trip.
@MainActor
final class StubEngine: ProxyControlling {
    var flows: [Flow] = []
    var rules = RulesState()
    var scope = SSLScope.disabled
    var cert = CertificateStatus.notGenerated
    var proxyStatus = ProxyStatus(isRunning: true, port: 9090, capturedCount: 0)
    var recording = true
    var devices: [DeviceSummary] = []

    // Spies
    private(set) var lastReplay: (id: UUID, overrides: ReplayOverrides)?
    private(set) var lastReplayFlow: (flow: Flow, overrides: ReplayOverrides)?
    private(set) var lastSSLScope: SSLScope?
    private(set) var setRulesEnabledCalls: [Bool] = []
    private(set) var addedRules: [TrafficRule] = []
    private(set) var deletedRuleIDs: [UUID] = []
    var replayResult: Flow?
    var replayError: Error?

    // FlowProviding
    /// Endpoints are folded in the way the real engine does (it reads them from its
    /// config), so a tool that renders them from the status sees them here too.
    func status() async -> ProxyStatus {
        var status = proxyStatus
        status.reverseProxies = storedReverseProxies
        return status
    }
    func recentFlows(limit: Int) async -> [Flow] { Array(flows.prefix(limit)) }
    func recentFlows(matching query: FlowQuery, limit: Int) async -> [Flow] {
        Array(flows.lazy.filter(query.matches).prefix(limit))
    }
    func recentFlowsForExport(limit: Int) async -> [Flow] { Array(flows.prefix(limit)) }
    func flow(id: UUID) async -> Flow? { flows.first { $0.id == id } }

    /// Live streams the blocking `wait_*` tools subscribe to. A test pushes through
    /// `emit`/`hold` to stand in for traffic arriving mid-wait; the streams stay open
    /// so a wait ends on its own deadline rather than on a finished stream.
    private var flowContinuations: [AsyncStream<Flow>.Continuation] = []
    private var pendingContinuations: [AsyncStream<PendingBreakpoint>.Continuation] = []

    /// Subscription bookkeeping — the observable trace of a blocking tool call, whose
    /// only footprint is its stream subscription: opened when the wait starts, ended
    /// when it finishes or is cancelled.
    private(set) var flowSubscriptionsOpened = 0
    private(set) var endedFlowSubscriptions = 0
    /// Same signal for the breakpoint side, so a `wait_for_pending` test can push a
    /// hold once the wait is actually listening rather than after a hopeful sleep.
    private(set) var pendingSubscriptionsOpened = 0

    func flowStream() async -> AsyncStream<Flow> {
        AsyncStream { continuation in
            flowContinuations.append(continuation)
            flowSubscriptionsOpened += 1
            continuation.onTermination = { _ in
                Task { @MainActor [weak self] in self?.endedFlowSubscriptions += 1 }
            }
        }
    }

    func pendingBreakpointStream() async -> AsyncStream<PendingBreakpoint> {
        AsyncStream { continuation in
            pendingContinuations.append(continuation)
            pendingSubscriptionsOpened += 1
        }
    }

    /// Push a flow to every subscriber, as the store's broadcast would.
    func emit(_ flow: Flow) {
        flows.insert(flow, at: 0)
        for continuation in flowContinuations { continuation.yield(flow) }
    }

    /// Park an exchange: it becomes visible to `pendingBreakpoints()` *and* is pushed.
    func hold(_ pending: PendingBreakpoint) {
        self.pending.append(pending)
        for continuation in pendingContinuations { continuation.yield(pending) }
    }

    func flowsClearedStream() async -> AsyncStream<Void> { AsyncStream { $0.finish() } }
    func connectedDevices() async -> [DeviceSummary] { devices }

    // FlowReplaying
    private(set) var replayCallCount = 0
    /// Highest number of replays that were ever in flight at the same moment — how a
    /// test observes that `concurrency` was actually honored.
    private(set) var peakConcurrentReplays = 0
    private var inFlightReplays = 0
    /// Per-attempt scripting for batch tests: status code, or an error, or a delay.
    /// Consumed in order; once exhausted, attempts fall back to the plain 200 below.
    enum ScriptedReplay {
        case status(Int)
        case failure(String)
        /// Succeeds with 200 after suspending, so overlapping attempts are observable.
        case slow(seconds: Double)
    }

    var replayScript: [ScriptedReplay] = []

    func replay(id: UUID, overrides: ReplayOverrides) async throws -> Flow {
        lastReplay = (id, overrides)
        replayCallCount += 1
        inFlightReplays += 1
        peakConcurrentReplays = max(peakConcurrentReplays, inFlightReplays)
        defer { inFlightReplays -= 1 }

        if let replayError { throw replayError }
        if let replayResult { return replayResult }

        let scripted = replayScript.isEmpty ? ScriptedReplay.status(200) : replayScript.removeFirst()
        let startedAt = Date()
        switch scripted {
        case let .failure(message):
            throw ProxyControlError.replayFailed(message)
        case let .slow(seconds):
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            return Self.replayed(of: id, status: 200, startedAt: startedAt)
        case let .status(code):
            return Self.replayed(of: id, status: code, startedAt: startedAt)
        }
    }

    private static func replayed(of id: UUID, status: Int, startedAt: Date) -> Flow {
        Flow(
            id: UUID(), request: CapturedRequest(method: "GET", url: "https://x/", headers: []),
            startedAt: startedAt,
            outcome: .completed(CapturedResponse(statusCode: status, headers: []), at: Date()),
            firstByteAt: startedAt.addingTimeInterval(0.05),
            replayedFrom: id
        )
    }

    func replay(flow: Flow, overrides: ReplayOverrides) async throws -> Flow {
        lastReplayFlow = (flow, overrides)
        if let replayError { throw replayError }
        if let replayResult { return replayResult }
        return Flow(id: UUID(), request: flow.request,
                    startedAt: Date(), outcome: .completed(CapturedResponse(statusCode: 200, headers: []), at: Date()),
                    replayedFrom: flow.id)
    }

    // TLSInterceptControlling
    func certificateStatus() async -> CertificateStatus { cert }
    func exportCACertificate() async throws -> URL { URL(fileURLWithPath: "/tmp/loom-ca.pem") }
    func sslScope() async -> SSLScope { scope }
    func setSSLScope(_ scope: SSLScope) async { self.scope = scope; lastSSLScope = scope }
    var tunneled = TunneledHostReport()
    func tunneledHosts() async -> TunneledHostReport { tunneled }
    private(set) var interceptedHosts: [String] = []
    func interceptHost(_ host: String) async -> InterceptOutcome {
        interceptedHosts.append(host)
        var next = scope
        let outcome = next.intercept(host: host)
        scope = next
        lastSSLScope = next
        return outcome
    }
    private(set) var stoppedHosts: [String] = []
    func stopInterceptingHost(_ host: String) async -> StopInterceptOutcome {
        stoppedHosts.append(host)
        var next = scope
        let outcome = next.stopIntercepting(host: host)
        scope = next
        lastSSLScope = next
        return outcome
    }

    // CaptureControlling
    func setRecording(_ recording: Bool) async { self.recording = recording }
    private(set) var importedFlows: [Flow] = []
    func importFlows(_ flows: [Flow]) async -> Int {
        importedFlows.append(contentsOf: flows)
        self.flows.insert(contentsOf: flows.reversed(), at: 0)
        return flows.count
    }

    private(set) var clearFlowsCallCount = 0
    func clearFlows() async {
        clearFlowsCallCount += 1
        flows.removeAll()
        proxyStatus.capturedCount = 0
    }

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
    func setRules(_ rules: [TrafficRule]) async -> SetRulesReport {
        var applied: [TrafficRule] = []
        var rejected: [SetRulesReport.Rejection] = []
        for rule in rules {
            if let reason = rule.validationError() {
                rejected.append(.init(id: rule.id, name: rule.name, reason: reason))
            } else {
                applied.append(rule)
            }
        }
        self.rules.rules = applied
        return SetRulesReport(applied: applied, rejected: rejected)
    }
    func setGroupEnabled(group: String?, enabled: Bool) async {
        // Mirrors `RulesConfig`: the group's own switch, never a batch write over
        // each member's flag.
        if enabled { rules.disabledGroups.remove(group) } else { rules.disabledGroups.insert(group) }
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

    // AuditControlling
    private(set) var recordedAudits: [AuditEntry] = []
    func recordAudit(_ entry: AuditEntry) async { recordedAudits.append(entry) }
    func recentAuditEntries(limit: Int) async -> [AuditEntry] {
        Array(recordedAudits.reversed().prefix(limit))
    }
    func auditStream() async -> AsyncStream<AuditEntry> { AsyncStream { $0.finish() } }
    func clearAudit() async { recordedAudits.removeAll() }

    // ClientCertificateControlling
    //
    // Stores what it was given without opening the bundle: the real store validates
    // PKCS#12 (and `ClientCertificateTests` covers that), while these tests are about
    // the tool surface — argument parsing, the audit record, and that secrets never
    // come back out.
    private(set) var storedClientCertificates: [ClientCertificate] = []
    var clientCertificateSetError: Error?

    func clientCertificates() async -> [ClientCertificateSummary] {
        storedClientCertificates.map {
            ClientCertificateSummary(
                id: $0.id, hostPattern: $0.hostPattern, label: $0.label, isEnabled: $0.isEnabled,
                subject: "CN=stub-client", notAfter: Date(timeIntervalSince1970: 4_000_000_000)
            )
        }
    }

    func setClientCertificate(_ certificate: ClientCertificate) async throws {
        if let clientCertificateSetError { throw clientCertificateSetError }
        if let index = storedClientCertificates.firstIndex(where: { $0.id == certificate.id }) {
            storedClientCertificates[index] = certificate
        } else {
            storedClientCertificates.append(certificate)
        }
    }

    func deleteClientCertificate(id: UUID) async throws {
        guard storedClientCertificates.contains(where: { $0.id == id }) else {
            throw ProxyControlError.clientCertificateNotFound(id)
        }
        storedClientCertificates.removeAll { $0.id == id }
    }

    // MARK: ReverseProxyControlling

    /// Endpoints plus a fake bound port, so the tools can be exercised without
    /// opening a real socket. The port allocation is deliberately trivial (a
    /// counter): what the tools are responsible for is validation, rendering and
    /// audit, not binding.
    private(set) var storedReverseProxies: [ReverseProxyStatus] = []
    private var nextStubPort = 9200

    func reverseProxies() async -> [ReverseProxyStatus] { storedReverseProxies }

    func createReverseProxy(_ endpoint: ReverseProxyEndpoint) async throws -> ReverseProxyStatus {
        var endpoint = endpoint
        endpoint.upstream = try ReverseProxyEndpoint.normalizedUpstream(endpoint.upstream)
        let port = endpoint.requestedPort == 0 ? nextStubPort : endpoint.requestedPort
        nextStubPort += 1
        let status = ReverseProxyStatus(endpoint: endpoint, boundPort: port)
        storedReverseProxies.append(status)
        return status
    }

    func deleteReverseProxy(id: UUID) async throws {
        guard storedReverseProxies.contains(where: { $0.endpoint.id == id }) else {
            throw ProxyControlError.reverseProxyNotFound(id)
        }
        storedReverseProxies.removeAll { $0.endpoint.id == id }
    }
}
