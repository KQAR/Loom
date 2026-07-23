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

    /// Lazily generated on first `start()` (or first cert query) and cached.
    private var ca: CertificateAuthority?

    private var running = false
    private var boundPort = 9090

    public init() {
        // Durable flow store (SQLite) so captures survive relaunch.
        self.store = FlowStore(persistence: FlowPersistence.makeDefault())
        let rulesConfig = RulesConfig() // persisted across launches (JSON file in App Support)
        self.rulesConfig = rulesConfig
        // Every exchange — plain HTTP, MITM'd HTTPS, and replay — re-sends through
        // this one forwarder, so decorating it applies traffic rules everywhere.
        // M4: a hand-rolled SwiftNIO client (owns the Host header, originates its
        // own TLS) replaces URLSession as the upstream leg.
        self.forwarder = RuleApplyingForwarder(base: NIOStreamingForwarder(group: group), rules: rulesConfig)
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
        self.forwarder = RuleApplyingForwarder(base: NIOStreamingForwarder(group: group), rules: rulesConfig)
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
        self.forwarder = RuleApplyingForwarder(base: forwarder, rules: rulesConfig)
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
            return boundPort
        } catch {
            running = false
            throw error
        }
    }

    public func stop() async {
        guard running else { return }
        await server.stop()
        running = false
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
