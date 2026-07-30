import Foundation
import LoomSharedModels

/// Everything that differs between the three ways a `ProxyEngine` gets built —
/// the app, an embedding host, and a test — in one value.
///
/// The engine used to have three initializers, each assembling the same forwarder
/// decorator chain, CA store, rules/scope configs and audit store by hand, under a
/// comment asking the next person to keep them in step. That comment was the only
/// thing holding the invariant, and the invariant matters: the decorator chain is
/// how Loom guarantees one write path, so a test-only chain that drifts from the
/// production one silently stops testing the thing that ships.
///
/// Internal on purpose. It names module-internal types (`CAStore`,
/// `UpstreamForwarding`), and the public API stays the two initializers an app or
/// an embedder actually needs.
struct EngineConfiguration {
    /// Where captured flows, the audit trail, rules and the SSL scope live.
    enum Persistence {
        /// SQLite stores + the rules file + UserDefaults: survives relaunch.
        case durable
        /// Nothing touches disk. For a test, or an embedder that owns retention.
        case inMemory
    }

    /// Size of the in-memory flow ring. `0` retains nothing between captures.
    var flowCapacity: Int = 2000
    var persistence: Persistence = .durable
    /// Push sink for flow inserts/updates (see `FlowObserving`).
    var flowObserver: FlowObserving?
    /// Overrides the file-backed CA store. Tests pass an in-memory one so no
    /// Keychain or app-support file is touched.
    var caStore: CAStore?
    /// Overrides the real SwiftNIO upstream leg. A test passes a deterministic
    /// stub — note it is injected *underneath* the rule and breakpoint decorators,
    /// so the chain under test is the shipped one.
    var upstream: UpstreamForwarding?
    /// Overrides where `exportCACertificate()` writes.
    var caExportURL: URL?
    /// Overrides the mutual-TLS identity store. Tests pass a non-persisting one so
    /// they can't read or clobber the operator's real client certificates — which,
    /// unlike rules, are credentials.
    var clientCertificates: ClientCertificateConfig?

    /// What `ProxyEngine.shared` runs on.
    static let `default` = EngineConfiguration()
}
