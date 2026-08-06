import Foundation
import Synchronization
import NIOSSL
import X509
import LoomSharedModels

/// A TLS context to present to a given host, or nil for "use the shared default".
///
/// The forwarder depends on this rather than on the config below so the upstream
/// leg stays ignorant of where identities are stored — a test (and an embedder)
/// can hand it one identity without a file.
protocol ClientIdentityProviding: Sendable {
    /// Client context for `host`, or nil when no identity is configured for it.
    /// Throws only when an identity *is* configured and cannot be loaded.
    func context(forHost host: String) throws -> NIOSSLContext?
    /// Context to use when no identity matches — same trust settings, no client
    /// certificate. Nil means "use the process-wide shared default".
    ///
    /// It exists so the no-identity path runs through the *same* trust
    /// configuration as the identity path. Without it a test that overrides the
    /// base configuration to trust its throwaway CA only overrides half the
    /// handshakes, and its no-identity case fails at server-certificate
    /// verification instead of where it claims to — which is exactly how
    /// `aRefusedHandshakeNamesWhetherAnIdentityWasPresented` passed while proving
    /// nothing.
    func baseContext() throws -> NIOSSLContext?
    /// Name of the identity that *would* be presented to `host`, for error context;
    /// nil when none matches.
    ///
    /// Separate from `context(forHost:)` because it is needed on the failure path,
    /// where building a context may be exactly what failed — and because naming the
    /// identity must never itself throw.
    func identityLabel(forHost host: String) -> String?
}

/// Thread-safe holder for the configured mutual-TLS identities, shared between the
/// actor (which mutates) and the forwarding path (which reads per request).
///
/// Two things it owns beyond storage:
///
/// 1. **Validation on the way in.** A bundle that can't be opened with its
///    passphrase is rejected at `set` time. The alternative is discovering it as a
///    handshake failure on some request later, attributed to the origin.
/// 2. **A context cache.** Building an `NIOSSLContext` parses the system trust
///    store *and* the bundle — tens of milliseconds — so doing it per request would
///    make every mTLS host slow in a way that looks like the server's fault. Keyed
///    by identity id and dropped wholesale on any mutation, which is correct
///    because an identity's bytes are immutable: a change means a new blob, so
///    there is nothing to reconcile and no staleness to reason about.
///
/// Persisted as one JSON file (0600, inside the 0700 app-support directory) with
/// the same lock-and-enqueue discipline as `RulesConfig`: the write is queued while
/// the lock is held so disk order can't diverge from mutation order.
final class ClientCertificateConfig: ClientIdentityProviding, Sendable {
    private struct State {
        var certificates: [ClientCertificate]
        var contexts: [UUID: NIOSSLContext] = [:]
        var cachedBaseContext: NIOSSLContext?
    }

    private let state: Mutex<State>
    private let fileURL: URL?
    private let persistQueue = DispatchQueue(label: "com.loom.clientcerts.persist")
    /// Base client TLS configuration the identity is layered onto. Production uses
    /// the system trust store; a test overrides it to trust its own throwaway CA so
    /// a real mutual-TLS handshake can be exercised through this same code (rather
    /// than a parallel one that proves nothing about it).
    private let baseConfiguration: @Sendable () -> TLSConfiguration
    /// Whether `baseConfiguration` was supplied by the caller. Only then is a
    /// separate no-identity context worth building — see `baseContext()`.
    private let isBaseConfigurationCustom: Bool

    /// - Parameter fileURL: persistence backing; `nil` disables it (tests, and any
    ///   engine that must not read or clobber the real set).
    init(
        certificates: [ClientCertificate] = [],
        fileURL: URL? = ClientCertificateConfig.defaultFileURL,
        baseConfiguration: (@Sendable () -> TLSConfiguration)? = nil
    ) {
        self.fileURL = fileURL
        self.isBaseConfigurationCustom = baseConfiguration != nil
        self.baseConfiguration = baseConfiguration ?? { .makeClientConfiguration() }
        if let fileURL, let saved = Self.load(from: fileURL) {
            self.state = Mutex(State(certificates: saved))
        } else {
            self.state = Mutex(State(certificates: certificates))
        }
    }

    /// `~/Library/Application Support/com.loom/client-certificates.json` — beside
    /// the CA store and the rules file, and owner-only for the same reason: this
    /// one holds private keys.
    static var defaultFileURL: URL? {
        LoomPaths.appSupportFile("client-certificates.json")
    }

    // MARK: - Reads

    func all() -> [ClientCertificate] {
        state.withLock { $0.certificates }
    }

    /// Secrets stripped, with each bundle's leaf parsed so an expired or
    /// unreadable identity is visible before it breaks a request.
    func summaries() -> [ClientCertificateSummary] {
        all().map { certificate in
            var summary = ClientCertificateSummary(
                id: certificate.id,
                hostPattern: certificate.hostPattern,
                label: certificate.label,
                isEnabled: certificate.isEnabled
            )
            do {
                let leaf = try Self.leaf(of: certificate)
                summary.subject = leaf.subject.description
                summary.notAfter = leaf.notValidAfter
            } catch {
                summary.problem = Self.describe(error)
            }
            return summary
        }
    }

    /// The enabled identity whose host pattern matches, most specific first — the
    /// longest pattern wins, so `api.corp.example` beats `*.corp.example` without
    /// depending on the order they happen to be stored in.
    func identity(forHost host: String) -> ClientCertificate? {
        all()
            .filter { $0.isEnabled && SSLScope.matches(pattern: $0.hostPattern, host: host) }
            .max { $0.hostPattern.count < $1.hostPattern.count }
    }

    func identityLabel(forHost host: String) -> String? {
        guard let identity = identity(forHost: host) else { return nil }
        // Both halves, because they answer different questions: the label is what the
        // operator named it, the pattern is *why* it was chosen — which is the part
        // that matters when two globs overlap.
        return identity.label == identity.hostPattern
            ? identity.hostPattern
            : "\(identity.label) (\(identity.hostPattern))"
    }

    /// Built once and cached: it is the same object for every host that has no
    /// identity, and building one parses the trust store. `nil` when the base
    /// configuration is the stock client one, so production keeps using the shared
    /// context instead of holding a second identical copy.
    func baseContext() throws -> NIOSSLContext? {
        guard isBaseConfigurationCustom else { return nil }
        // Two critical sections rather than one, deliberately: building the context
        // parses the trust store and must not happen under the lock.
        if let cached = state.withLock({ $0.cachedBaseContext }) { return cached }
        let context = try NIOSSLContext(configuration: baseConfiguration())
        state.withLock { $0.cachedBaseContext = context }
        return context
    }

    func context(forHost host: String) throws -> NIOSSLContext? {
        guard let identity = identity(forHost: host) else { return nil }
        // Same two-section shape as `baseContext()`, and for the same reason.
        if let cached = state.withLock({ $0.contexts[identity.id] }) { return cached }
        let context = try makeContext(for: identity)
        state.withLock { $0.contexts[identity.id] = context }
        return context
    }

    // MARK: - Writes

    /// Add or replace by id. Rejects a bundle that can't be opened — see the type's
    /// note on why that check belongs here and not at handshake time.
    func set(_ certificate: ClientCertificate) throws {
        guard !certificate.hostPattern.isEmpty else {
            throw ProxyControlError.invalidClientCertificate("hostPattern must not be empty")
        }
        do {
            _ = try Self.bundle(of: certificate)
        } catch {
            throw ProxyControlError.invalidClientCertificate(Self.describe(error))
        }
        mutate { certificates in
            if let index = certificates.firstIndex(where: { $0.id == certificate.id }) {
                certificates[index] = certificate
            } else {
                certificates.append(certificate)
            }
        }
    }

    /// Returns false when there was no such id.
    func delete(id: UUID) -> Bool {
        mutate { certificates in
            let before = certificates.count
            certificates.removeAll { $0.id == id }
            return certificates.count != before
        }
    }

    @discardableResult
    private func mutate<T>(_ body: (inout [ClientCertificate]) -> T) -> T {
        state.withLock { state in
            let result = body(&state.certificates)
            let updated = state.certificates
            // Any mutation invalidates every built context. Cheap: identities are few
            // and a context is rebuilt on the next request to that host.
            state.contexts = [:]
            if let fileURL { persistQueue.async { Self.persist(updated, to: fileURL) } }
            return result
        }
    }

    /// Block until queued writes have run — the quit handler, and any test that
    /// reads the file straight after mutating.
    func flush() {
        persistQueue.sync {}
    }

    // MARK: - Bundles

    private static func bundle(of certificate: ClientCertificate) throws -> NIOSSLPKCS12Bundle {
        try NIOSSLPKCS12Bundle(
            buffer: Array(certificate.pkcs12),
            // An empty string is not the same as no passphrase: BoringSSL treats a
            // zero-length passphrase differently from a nil one, and an unprotected
            // export needs the nil.
            passphrase: certificate.passphrase.isEmpty ? nil : Array(certificate.passphrase.utf8)
        )
    }

    private static func leaf(of certificate: ClientCertificate) throws -> Certificate {
        let bundle = try bundle(of: certificate)
        guard let first = bundle.certificateChain.first else {
            throw ProxyControlError.invalidClientCertificate("bundle contains no certificate")
        }
        return try Certificate(derEncoded: try first.toDERBytes())
    }

    private func makeContext(for certificate: ClientCertificate) throws -> NIOSSLContext {
        let bundle = try Self.bundle(of: certificate)
        var configuration = baseConfiguration()
        configuration.certificateChain = bundle.certificateChain.map { .certificate($0) }
        configuration.privateKey = .privateKey(bundle.privateKey)
        return try NIOSSLContext(configuration: configuration)
    }

    /// NIOSSL reports a wrong passphrase and a non-PKCS#12 blob the same way (a
    /// BoringSSL error stack), so the message says what the operator can act on
    /// rather than pretending to know which it was.
    private static func describe(_ error: Error) -> String {
        if let error = error as? ProxyControlError { return error.message }
        return "could not read the PKCS#12 bundle — wrong passphrase, or not a .p12/.pfx file (\(error))"
    }

    // MARK: - Persistence

    private static func persist(_ certificates: [ClientCertificate], to url: URL) {
        do {
            let data = try JSONEncoder().encode(certificates)
            try LoomPaths.createSecureDirectory(at: url.deletingLastPathComponent())
            try data.write(to: url, options: .atomic)
            LoomPaths.restrictToOwner(url)
        } catch {
            Log.store.error("Client certificates persist failed; changes may not survive relaunch: \(String(describing: error))")
        }
    }

    private static func load(from url: URL) -> [ClientCertificate]? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil } // first run
        do {
            return try JSONDecoder().decode([ClientCertificate].self, from: Data(contentsOf: url))
        } catch {
            // Fail open, loudly: every mTLS host silently reverts to presenting no
            // identity, and its handshake failures would look like the origin's fault.
            Log.tls.error("""
            Client certificates file at \(url.path, privacy: .public) could not be read; \
            starting with none — mutual-TLS hosts will fail their handshake: \
            \(String(describing: error))
            """)
            return nil
        }
    }
}
