import Foundation
import NIOPosix
import LoomSharedModels

/// The single source of truth for proxy state and captured flows. Both the TCA
/// `ProxyClient` and the `MCPServer` talk to this same shared instance, so AI
/// actions and UI actions run through one write path.
///
/// This file holds the actor's state, how it is wired together, and its
/// lifecycle. Each protocol it conforms to is implemented in its own extension
/// file — `ProxyEngine+Flows`, `+TLS`, `+Rules`, `+Breakpoints`, `+Audit`,
/// `+Replay`, plus `+PhoneOnboarding` — because the engine is a *façade*: nearly
/// every method delegates to the collaborator that owns the behaviour
/// (`FlowStore`, `RulesConfig`, `BreakpointStore`, `AuditStore`), and one file
/// listing all of them read like a god object while the actual logic lived
/// elsewhere. Splitting by protocol makes the delegation visible and keeps the
/// façade the only thing anyone has to hold in their head here.
///
/// The stored state below is module-internal rather than `private` for exactly
/// that reason: `private` is file-scoped, and the conformances are now siblings.
public actor ProxyEngine: ProxyControlling {
    public static let shared = ProxyEngine()

    let store: FlowStore
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 2)
    lazy var server = ProxyServer(group: group)

    let forwarder: UpstreamForwarding
    let caStore: CAStore
    let config: InterceptionConfig
    let rulesConfig: RulesConfig
    /// Holds armed breakpoints and currently-paused exchanges. Shared with the
    /// `BreakpointForwarder` wrapping `forwarder`, off the actor so forwarding can
    /// check for a breakpoint without hopping here.
    let breakpointStore: BreakpointStore
    /// Durable trail of MCP write actions (replay / rules / breakpoints /
    /// ssl-scope). The MCP tool choke point records here; the UI and an agent read
    /// it back. See `AuditControlling`.
    let auditStore: AuditStore

    /// Lazily generated on first `start()` (or first cert query) and cached.
    var ca: CertificateAuthority?

    var running = false
    /// Set for the duration of `stop()` so a reentrant stop bails instead of
    /// tearing the server down twice (see `stop()`).
    var stopping = false
    /// Set for the duration of `startPhoneOnboarding()` — it awaits several times
    /// while creating a provisioning server, and two concurrent calls would each
    /// build one and race for the same port.
    var startingPhoneOnboarding = false
    /// Size of the in-memory flow ring, mirrored here so `start()` restores at
    /// most a ring's worth of persisted flows.
    let flowCapacity: Int
    var boundPort = 9090
    /// Interface the proxy is currently bound to. Phone onboarding flips this to
    /// `0.0.0.0` (LAN-reachable) and back to loopback when it ends.
    var currentBindHost = "127.0.0.1"
    var lastObserveTunnels = false

    /// LAN-facing CA/profile download server + last-published info, live only
    /// while phone onboarding is active.
    var provisioning: ProvisioningServer?
    var phoneInfo: PhoneOnboardingInfo?

    /// The default engine: durable SQLite flow + audit stores, persisted rules and
    /// SSL scope, file-backed CA. What `ProxyEngine.shared` is.
    public init() {
        self.init(configuration: .default)
    }

    /// Host-embeddable init for any Swift consumer that drives the engine as a
    /// library and keeps captured flows in its own store. Pass `persistFlows:
    /// false` to keep flows only in the in-memory ring and the live
    /// `flowStream()`, so there is no second on-disk copy in Loom's SQLite store.
    ///
    /// - Parameters:
    ///   - capacity: size of the in-memory flow ring. An embedder that owns its
    ///     own storage and replays via `replay(flow:overrides:)` can shrink this
    ///     to bound Loom's retention. `capacity: 0` is **store-less**: nothing is
    ///     retained between captures — flows land only on `flowStream()` / the
    ///     `observer` below (and `replay(id:)` / `recentFlows` return nothing, so
    ///     replay via `replay(flow:)`).
    ///   - observer: an optional push sink delivered every flow insert/update,
    ///     the same payload as `flowStream()` but pushed. See `FlowObserving`.
    public init(persistFlows: Bool, capacity: Int = 2000, observer: FlowObserving? = nil) {
        self.init(configuration: EngineConfiguration(
            flowCapacity: capacity,
            // The audit trail follows the flow store: persist only when the
            // embedder lets Loom own storage.
            persistence: persistFlows ? .durable : .inMemory,
            flowObserver: observer
        ))
    }

    /// Test seam: inject a deterministic forwarder and an in-memory CA store so
    /// interception can be exercised without the network or the Keychain. Nothing
    /// touches disk, UserDefaults, or the user's exported CA file.
    init(forwarder: UpstreamForwarding, caStore: CAStore) {
        self.init(configuration: EngineConfiguration(
            persistence: .inMemory,
            caStore: caStore,
            upstream: forwarder,
            // Hermetic: never let a test clobber the user's real exported CA file.
            caExportURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("loom-ca-test-\(UUID()).pem")
        ))
    }

    /// The one place the engine is wired together.
    ///
    /// There used to be three initializers — app, embedder, test — each assembling
    /// the same forwarder decorator chain, CA store, configs and audit store by
    /// hand, with a comment asking the next person to mirror any change into the
    /// other two. A comment is not an invariant. Everything variable now lives in
    /// `EngineConfiguration`, and every entry point funnels through here, so the
    /// chain that production runs is the chain tests run.
    private init(configuration: EngineConfiguration) {
        self.flowCapacity = configuration.flowCapacity
        let durable = configuration.persistence == .durable
        self.store = FlowStore(
            capacity: configuration.flowCapacity,
            persistence: durable ? FlowPersistence.makeDefault() : nil,
            observer: configuration.flowObserver
        )
        self.auditStore = AuditStore(persistence: durable ? AuditPersistence.makeDefault() : nil)
        // Rules and SSL scope persist across launches for the app; a test-seam
        // engine gets non-persisting ones so it can't read or clobber the real set.
        let rulesConfig = durable ? RulesConfig() : RulesConfig(fileURL: nil)
        self.rulesConfig = rulesConfig
        self.config = durable ? InterceptionConfig() : InterceptionConfig(defaults: nil)

        // Every exchange — plain HTTP, MITM'd HTTPS, and replay — re-sends through
        // this one forwarder, so decorating it applies breakpoints and traffic
        // rules everywhere. M4: a hand-rolled SwiftNIO client (owns the Host
        // header, originates its own TLS) is the upstream leg.
        let breakpointStore = BreakpointStore()
        self.breakpointStore = breakpointStore
        let upstream = configuration.upstream ?? NIOStreamingForwarder(group: group)
        self.forwarder = BreakpointForwarder(
            base: RuleApplyingForwarder(base: upstream, rules: rulesConfig),
            store: breakpointStore
        )

        // File-backed CA store: reading it triggers no Keychain ACL prompt, so a
        // rebuilt (ad-hoc re-signed) app doesn't ask for the login password every
        // launch. One-time migration preserves an already-trusted Keychain CA.
        self.caStore = configuration.caStore ?? Self.migratedCAStore()
        self.caExportURL = configuration.caExportURL ?? Self.defaultCAExportURL
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
            await store.loadPersisted(limit: flowCapacity) // restore at most a ring's worth
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
        // `running` has to stay true across the awaits below so a reentrant
        // `start()` still bails at its guard — which means it can't double as the
        // "already stopping" flag. Claim `stopping` synchronously instead, the
        // mirror of what `start()` does with `running`.
        guard running, !stopping else { return }
        stopping = true
        await provisioning?.stop()
        provisioning = nil
        phoneInfo = nil
        await server.stop()
        running = false
        stopping = false
        currentBindHost = "127.0.0.1"
    }

    public var isRunning: Bool { running }

    /// Persist everything to disk before the app dies. Call from the terminate
    /// handler. Two gaps closed: (1) flows still in flight (`.pending`/streaming)
    /// live only in the ring and never got saved — finalize them as interrupted
    /// and write them; (2) completed flows are saved fire-and-forget, so drain the
    /// write queue afterwards so a quit can't outrun the last few writes.
    public func flushFlows() async {
        await store.finalizeInFlight(reason: "interrupted (app quit)")
        await store.flush()
        await auditStore.flush()
        // Rules and the SSL scope persist off a serial queue too, so a quit can
        // outrun the last edit the same way it could outrun the last flow.
        rulesConfig.flush()
        config.flush()
    }

    // MARK: - Certificate authority

    /// Generate-or-load the CA once. Failure leaves interception unavailable but
    /// keeps plain capture and blind tunneling working. Internal so the TLS and
    /// phone-onboarding extensions can reach it.
    func ensureCA() -> CertificateAuthority? {
        if let ca { return ca }
        do {
            ca = try CertificateAuthority.loadOrGenerate(store: caStore)
        } catch {
            Log.tls.error("CA load/generate failed; HTTPS interception unavailable: \(String(describing: error))")
        }
        return ca
    }

    /// Last path `exportCACertificate()` wrote to, surfaced in `certificateStatus`.
    var exportedPEMPath: URL?

    /// Where `exportCACertificate()` writes. The test-seam init points this at a
    /// temp file so tests can't overwrite the user's real exported CA.
    let caExportURL: URL

    static var defaultCAExportURL: URL {
        LoomPaths.appSupportFile("loom-ca.pem")
    }
}
