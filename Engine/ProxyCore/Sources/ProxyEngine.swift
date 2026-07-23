import Foundation
import NIOPosix
import SharedModels

/// The single source of truth for proxy state and captured flows. Both the TCA
/// `ProxyClient` and the `MCPServer` talk to this same shared instance, so AI
/// actions and UI actions run through one write path.
public actor ProxyEngine: ProxyControlling {
    public static let shared = ProxyEngine()

    private let store: FlowStore
    private let group = MultiThreadedEventLoopGroup(numberOfThreads: 2)
    private lazy var server = ProxyServer(group: group)

    private let forwarder: UpstreamForwarding
    private let caStore: CAStore
    private let config: InterceptionConfig
    private let rulesConfig: RulesConfig
    /// Holds armed breakpoints and currently-paused exchanges. Shared with the
    /// `BreakpointForwarder` wrapping `forwarder`, off the actor so forwarding can
    /// check for a breakpoint without hopping here.
    private let breakpointStore: BreakpointStore

    /// Lazily generated on first `start()` (or first cert query) and cached.
    private var ca: CertificateAuthority?

    private var running = false
    private var boundPort = 9090
    /// Interface the proxy is currently bound to. Phone onboarding flips this to
    /// `0.0.0.0` (LAN-reachable) and back to loopback when it ends.
    private var currentBindHost = "127.0.0.1"
    private var lastObserveTunnels = false

    /// LAN-facing CA/profile download server + last-published info, live only
    /// while phone onboarding is active.
    private var provisioning: ProvisioningServer?
    private var phoneInfo: PhoneOnboardingInfo?

    public init() {
        // Durable flow store (SQLite) so captures survive relaunch.
        self.store = FlowStore(persistence: FlowPersistence.makeDefault())
        let rulesConfig = RulesConfig() // persisted across launches (JSON file in App Support)
        self.rulesConfig = rulesConfig
        // Every exchange — plain HTTP, MITM'd HTTPS, and replay — re-sends through
        // this one forwarder, so decorating it applies traffic rules everywhere.
        // M4: a hand-rolled SwiftNIO client (owns the Host header, originates its
        // own TLS) replaces URLSession as the upstream leg.
        let breakpointStore = BreakpointStore()
        self.breakpointStore = breakpointStore
        self.forwarder = BreakpointForwarder(
            base: RuleApplyingForwarder(base: NIOStreamingForwarder(group: group), rules: rulesConfig),
            store: breakpointStore
        )
        // File-backed CA store: reading it triggers no Keychain ACL prompt, so a
        // rebuilt (ad-hoc re-signed) app doesn't ask for the login password every
        // launch. One-time migration preserves an already-trusted Keychain CA.
        self.caStore = Self.migratedCAStore()
        self.config = InterceptionConfig() // persisted across launches (UserDefaults)
        self.caExportURL = Self.defaultCAExportURL
    }

    /// Host-embeddable init for any Swift consumer that drives the engine as a
    /// library and keeps captured flows in its own store. Pass `persistFlows:
    /// false` to keep flows only in the in-memory ring and the live
    /// `flowStream()`, so there is no second on-disk copy in Loom's SQLite store.
    /// Forwarder, CA, and rules match `init()`.
    /// Kept as a sibling designated init (not a delegating convenience init) so
    /// `FlowPersistence` stays internal to the module. Mirror any change to the
    /// forwarder/CA/config wiring in `init()` above.
    public init(persistFlows: Bool) {
        self.store = FlowStore(persistence: persistFlows ? FlowPersistence.makeDefault() : nil)
        let rulesConfig = RulesConfig()
        self.rulesConfig = rulesConfig
        let breakpointStore = BreakpointStore()
        self.breakpointStore = breakpointStore
        self.forwarder = BreakpointForwarder(
            base: RuleApplyingForwarder(base: NIOStreamingForwarder(group: group), rules: rulesConfig),
            store: breakpointStore
        )
        self.caStore = Self.migratedCAStore()
        self.config = InterceptionConfig()
        self.caExportURL = Self.defaultCAExportURL
    }

    /// Return the file store, first migrating a legacy Keychain CA into it if the
    /// file is empty (so users who already trusted a Keychain-stored CA keep it).
    /// The Keychain is only touched when the file is empty AND an item exists —
    /// missing items return `errSecItemNotFound` without a prompt.
    private static func migratedCAStore() -> CAStore {
        let fileStore = FileCAStore()
        if (try? fileStore.load()) == nil, let legacy = try? KeychainCAStore().load() {
            try? fileStore.save(legacy)
        }
        return fileStore
    }

    /// Test seam: inject a deterministic forwarder and an in-memory CA store so
    /// interception can be exercised without the network or the Keychain. The
    /// config is non-persisting so tests never read or clobber the real scope.
    init(forwarder: UpstreamForwarding, caStore: CAStore) {
        self.store = FlowStore(persistence: nil) // no disk in tests
        let rulesConfig = RulesConfig(fileURL: nil)
        self.rulesConfig = rulesConfig
        let breakpointStore = BreakpointStore()
        self.breakpointStore = breakpointStore
        self.forwarder = BreakpointForwarder(
            base: RuleApplyingForwarder(base: forwarder, rules: rulesConfig),
            store: breakpointStore
        )
        self.caStore = caStore
        self.config = InterceptionConfig(defaults: nil)
        // Hermetic: never let a test clobber the user's real exported CA file.
        self.caExportURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("loom-ca-test-\(UUID()).pem")
    }

    // MARK: - Lifecycle

    @discardableResult
    public func start(port: Int = 9090, host: String = "127.0.0.1", observeTunnels: Bool = false) async throws -> Int {
        guard !running else { return boundPort }
        // Claim `running` synchronously, before the first await, so a reentrant
        // start() (actor reentrancy during the awaits below) bails at the guard
        // instead of racing a second bind on the same port. Reverted on failure
        // so a bind error (port in use) can still be retried.
        running = true
        do {
            await store.loadPersisted(limit: 2000) // restore prior captures once
            let ca = ensureCA()
            boundPort = try await server.start(
                host: host,
                port: port,
                store: store,
                forwarder: forwarder,
                ca: ca,
                config: config,
                observeTunnels: observeTunnels
            )
            currentBindHost = host
            lastObserveTunnels = observeTunnels
            return boundPort
        } catch {
            running = false
            throw error
        }
    }

    public func stop() async {
        guard running else { return }
        await provisioning?.stop()
        provisioning = nil
        phoneInfo = nil
        await server.stop()
        running = false
        currentBindHost = "127.0.0.1"
    }

    public var isRunning: Bool { running }

    public func clearFlows() async {
        await store.clear()
    }

    // MARK: - CaptureControlling

    /// Pause/resume recording. Forwarding (and MITM decryption) is unaffected;
    /// paused means observed traffic just isn't stored as flows.
    public func setRecording(_ recording: Bool) async {
        await store.setRecording(recording)
    }

    /// Generate-or-load the CA once. Failure leaves interception unavailable but
    /// keeps plain capture and blind tunneling working.
    private func ensureCA() -> CertificateAuthority? {
        if let ca { return ca }
        do {
            ca = try CertificateAuthority.loadOrGenerate(store: caStore)
        } catch {
            Log.tls.error("CA load/generate failed; HTTPS interception unavailable: \(String(describing: error))")
        }
        return ca
    }

    // MARK: - FlowProviding

    public func status() async -> ProxyStatus {
        ProxyStatus(
            isRunning: running,
            port: boundPort,
            capturedCount: await store.count,
            isRecording: await store.isRecording
        )
    }

    public func recentFlows(limit: Int) async -> [Flow] {
        await store.recent(limit: limit)
    }

    public func flow(id: UUID) async -> Flow? {
        await store.flow(id: id)
    }

    public func flowStream() async -> AsyncStream<Flow> {
        await store.stream()
    }

    /// Aggregate captured flows by originating device (keyed on remote IP). LAN
    /// devices sort ahead of this Mac, then by most-recently-seen — the phone you
    /// just pointed at Loom floats to the top.
    public func connectedDevices() async -> [DeviceSummary] {
        let flows = await store.recent(limit: await store.count)
        var byIP: [String: DeviceSummary] = [:]
        for flow in flows {
            guard let device = flow.sourceDevice else { continue }
            let at = flow.startedAt
            if var summary = byIP[device.groupingKey] {
                summary.flowCount += 1
                if at > summary.lastActive { summary.lastActive = at }
                // Keep the richest typing seen for this device across its flows.
                if summary.device.platform == nil { summary.device.platform = device.platform }
                if summary.device.client == nil { summary.device.client = device.client }
                byIP[device.groupingKey] = summary
            } else {
                byIP[device.groupingKey] = DeviceSummary(device: device, flowCount: 1, lastActive: at)
            }
        }
        return byIP.values.sorted { a, b in
            if (a.device.kind == .lan) != (b.device.kind == .lan) { return a.device.kind == .lan }
            return a.lastActive > b.lastActive
        }
    }

    // MARK: - TLSInterceptControlling

    public func certificateStatus() async -> CertificateStatus {
        guard let ca = ensureCA() else { return .notGenerated }
        return CertificateStatus(
            isGenerated: true,
            isTrusted: CertificateTrust.isTrusted(pem: ca.caCertificatePEM()),
            commonName: CertificateAuthority.commonName,
            sha256Fingerprint: ca.sha256Fingerprint,
            notAfter: ca.certificate.notValidAfter,
            exportedPEMPath: exportedPEMPath?.path
        )
    }

    /// DER bytes of the root CA, for a one-click keychain install via the helper.
    /// Not part of `TLSInterceptControlling` — the TCA client reaches it directly.
    public func caCertificateDER() async -> Data? {
        ensureCA()?.caCertificateDER()
    }

    /// Trust the root CA for the current user (login keychain + user-domain trust).
    /// Needs no privileged helper; macOS prompts once for the login password. Runs
    /// off the actor's executor because the prompt is modal. Returns `(ok, message)`.
    public func trustCACertificate() async -> (Bool, String?) {
        guard let der = ensureCA()?.caCertificateDER() else {
            return (false, "root CA unavailable")
        }
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                switch CertificateTrust.installUserTrust(der: der) {
                case .trusted: continuation.resume(returning: (true, nil))
                case .cancelled: continuation.resume(returning: (false, "Trust request was cancelled."))
                case let .failed(reason): continuation.resume(returning: (false, reason))
                }
            }
        }
    }

    public func exportCACertificate() async throws -> URL {
        guard let ca = ensureCA() else {
            throw ProxyControlError.certificateUnavailable("root CA could not be generated")
        }
        let url = caExportURL
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try ca.exportCACertificate(to: url)
        exportedPEMPath = url
        return url
    }

    /// Export the root CA into `directory` in both PEM and DER form, for an
    /// embedder whose device-trust flow needs the files at a known location (a
    /// device profile wants DER; `curl --cacert` and most desktop trust stores
    /// want PEM). One call instead of stitching `caCertificateDER()` +
    /// `exportCACertificate()` + a copy. Returns the written URLs.
    @discardableResult
    public func exportCA(
        toDirectory directory: URL,
        pemName: String = "loom-ca.pem",
        derName: String = "loom-ca.cer"
    ) async throws -> (pem: URL, der: URL) {
        guard let ca = ensureCA() else {
            throw ProxyControlError.certificateUnavailable("root CA could not be generated")
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let pemURL = directory.appendingPathComponent(pemName)
        let derURL = directory.appendingPathComponent(derName)
        try ca.exportCACertificate(to: pemURL)
        try ca.caCertificateDER().write(to: derURL, options: .atomic)
        exportedPEMPath = pemURL
        return (pem: pemURL, der: derURL)
    }

    public func sslScope() async -> SSLScope {
        config.snapshot()
    }

    public func setSSLScope(_ scope: SSLScope) async {
        _ = ensureCA() // make sure a CA exists before we start intercepting
        config.update(scope)
    }

    // MARK: - Phone onboarding

    /// Make the proxy reachable from a phone and publish everything the phone
    /// needs to route through it and trust the CA. Not part of `ProxyControlling`
    /// — an extra public capability on the engine (like `caCertificateDER()`),
    /// reusable by any embedder.
    ///
    /// Rebinds the proxy to `0.0.0.0` (LAN-reachable), starts a provisioning
    /// server serving the CA + iOS profile + a landing page, and encodes that
    /// page's URL as a QR code. Idempotent: called again it tears down the prior
    /// provisioning server and republishes (e.g. after the LAN IP changed).
    ///
    /// - Parameter provisioningPort: the download-server port; `0` (default) lets
    ///   the OS pick one.
    @discardableResult
    public func startPhoneOnboarding(provisioningPort: Int = 0) async throws -> PhoneOnboardingInfo {
        guard let ca = ensureCA() else {
            throw ProxyControlError.certificateUnavailable("root CA could not be generated")
        }
        guard let lanHost = LANAddress.primaryIPv4() else {
            throw ProxyControlError.phoneOnboardingUnavailable("no LAN IPv4 address — is this machine on Wi-Fi/Ethernet?")
        }

        // The phone can only reach the proxy if it isn't bound to loopback.
        if !running {
            _ = try await start(port: boundPort, host: "0.0.0.0")
        } else if currentBindHost != "0.0.0.0" {
            try await rebind(host: "0.0.0.0")
        }

        // Fresh provisioning server (drop any prior one).
        await provisioning?.stop()
        let content = ProvisioningContent(
            caPEM: ca.caCertificatePEM(),
            caDER: ca.caCertificateDER(),
            fingerprint: ca.sha256Fingerprint,
            commonName: CertificateAuthority.commonName,
            proxyHost: lanHost,
            proxyPort: boundPort
        )
        let server = ProvisioningServer(group: group)
        let provPort = try await server.start(host: "0.0.0.0", port: provisioningPort, content: content)
        provisioning = server

        guard let url = URL(string: "http://\(lanHost):\(provPort)/") else {
            await server.stop()
            provisioning = nil
            throw ProxyControlError.phoneOnboardingUnavailable("could not form provisioning URL")
        }

        let info = PhoneOnboardingInfo(
            lanHost: lanHost,
            proxyPort: boundPort,
            provisioningPort: provPort,
            provisioningURL: url,
            fingerprint: ca.sha256Fingerprint,
            commonName: CertificateAuthority.commonName,
            qrPNGData: QRCode.generate(from: url.absoluteString)?.pngData ?? Data()
        )
        phoneInfo = info
        return info
    }

    /// Stop serving provisioning material and return the proxy to loopback-only.
    public func stopPhoneOnboarding() async {
        await provisioning?.stop()
        provisioning = nil
        phoneInfo = nil
        if running, currentBindHost != "127.0.0.1" {
            try? await rebind(host: "127.0.0.1")
        }
    }

    /// The current onboarding info, or `nil` when phone onboarding is inactive.
    public func phoneOnboardingInfo() async -> PhoneOnboardingInfo? {
        phoneInfo
    }

    /// Move the running listener to a different interface on the same port. The
    /// flow store, CA and rules are untouched — only the accepting socket moves.
    private func rebind(host: String) async throws {
        guard running else { return }
        await server.stop()
        boundPort = try await server.start(
            host: host,
            port: boundPort,
            store: store,
            forwarder: forwarder,
            ca: ensureCA(),
            config: config,
            observeTunnels: lastObserveTunnels
        )
        currentBindHost = host
    }

    // MARK: - RulesControlling

    public func rulesState() async -> RulesState {
        rulesConfig.snapshot()
    }

    public func setRulesEnabled(_ enabled: Bool) async {
        rulesConfig.setEnabled(enabled)
    }

    public func addRule(_ rule: TrafficRule) async throws {
        if let reason = rule.validationError() {
            throw ProxyControlError.invalidRule(reason)
        }
        rulesConfig.add(rule)
    }

    public func updateRule(_ rule: TrafficRule) async throws {
        if let reason = rule.validationError() {
            throw ProxyControlError.invalidRule(reason)
        }
        guard rulesConfig.update(rule) else {
            throw ProxyControlError.ruleNotFound(rule.id)
        }
    }

    public func deleteRule(id: UUID) async throws {
        guard rulesConfig.delete(id: id) else {
            throw ProxyControlError.ruleNotFound(id)
        }
    }

    public func setRules(_ rules: [TrafficRule]) async throws {
        // Validate every rule before touching state so one bad rule can't leave a
        // half-applied set.
        for rule in rules {
            if let reason = rule.validationError() {
                throw ProxyControlError.invalidRule(reason)
            }
        }
        rulesConfig.replaceAll(rules)
    }

    public func setGroupEnabled(group: String?, enabled: Bool) async {
        rulesConfig.setGroupEnabled(group: group, enabled: enabled)
    }

    // MARK: - BreakpointControlling

    public func armBreakpoint(_ breakpoint: Breakpoint) async throws {
        if let reason = breakpoint.validationError {
            throw ProxyControlError.invalidBreakpoint(reason)
        }
        breakpointStore.arm(breakpoint)
    }

    public func disarmBreakpoint(id: UUID) async throws {
        guard breakpointStore.disarm(id: id) else {
            throw ProxyControlError.breakpointNotFound(id)
        }
    }

    public func armedBreakpoints() async -> [Breakpoint] {
        breakpointStore.armed()
    }

    public func pendingBreakpoints() async -> [PendingBreakpoint] {
        breakpointStore.pending()
    }

    public func resumeBreakpoint(pendingID: UUID, abort: Bool, edit: BreakpointEdit) async throws {
        let resolution: BreakpointResolution = abort ? .abort : .proceed(edit)
        guard breakpointStore.resume(pendingID: pendingID, resolution: resolution) else {
            throw ProxyControlError.pendingBreakpointNotFound(pendingID)
        }
    }

    private var exportedPEMPath: URL?

    /// Where `exportCACertificate()` writes. The test-seam init points this at a
    /// temp file so tests can't overwrite the user's real exported CA.
    private let caExportURL: URL

    private static var defaultCAExportURL: URL {
        LoomPaths.appSupportFile("loom-ca.pem")
    }

    // MARK: - FlowReplaying

    public func replay(id: UUID, overrides: ReplayOverrides) async throws -> Flow {
        guard let source = await store.flow(id: id) else {
            throw ProxyControlError.flowNotFound(id)
        }

        let method = overrides.method ?? source.request.method
        let urlString = overrides.url ?? source.request.url
        guard let url = URL(string: urlString) else {
            throw ProxyControlError.invalidURL(urlString)
        }

        var headers = source.request.headers
        if let removals = overrides.removeHeaders {
            let lowered = Set(removals.map { $0.lowercased() })
            headers.removeAll { lowered.contains($0.name.lowercased()) }
        }
        if let sets = overrides.setHeaders {
            for header in sets {
                headers.removeAll { $0.name.lowercased() == header.name.lowercased() }
                headers.append(header)
            }
        }

        let body: Data?
        switch overrides.body {
        case .keep: body = source.request.body
        case .clear: body = nil
        case let .replace(data): body = data
        }
        let capturedRequest = CapturedRequest(method: method, url: urlString, headers: headers, body: body)

        let newID = UUID()
        let startedAt = Date()
        do {
            let result = try await forwarder.forward(method: method, url: url, headers: headers, body: body)
            let flow = Flow(
                id: newID,
                request: capturedRequest,
                startedAt: startedAt,
                outcome: .completed(
                    CapturedResponse(statusCode: result.statusCode, httpVersion: result.httpVersion, headers: result.headers, body: result.body),
                    at: Date()
                ),
                replayedFrom: id,
                appliedRules: result.appliedRules.isEmpty ? nil : result.appliedRules
            )
            await store.upsert(flow, force: true) // explicit action: record even when capture is paused
            return flow
        } catch {
            let flow = Flow(
                id: newID,
                request: capturedRequest,
                startedAt: startedAt,
                outcome: .failed(FlowError(error.localizedDescription), at: Date(), partialResponse: nil),
                replayedFrom: id
            )
            await store.upsert(flow, force: true)
            throw ProxyControlError.replayFailed(error.localizedDescription)
        }
    }
}
