import Foundation
import LoomSharedModels

/// Thread-safe holder for the configured reverse-proxy endpoints, persisted as JSON
/// under Application Support.
///
/// Persisted for a usability reason, not a purity one: an endpoint's port is written
/// into a *dev server's* config (`vite.config.js`, `webpack.devServer.proxy`), and
/// that file doesn't change when Loom restarts. An endpoint that evaporated on quit
/// would break the developer's setup every morning, silently — the dev server would
/// just get connection-refused.
///
/// Same lock + serial-queue shape as `RulesConfig`, for the same reason: the write is
/// **enqueued while the lock is held** so the file can only move forward through the
/// states the in-memory value did, while the encode + write themselves stay off the
/// lock.
final class ReverseProxyConfig: @unchecked Sendable {
    private let lock = NSLock()
    private var endpoints: [ReverseProxyEndpoint]
    /// Bind results, keyed by endpoint id. Not persisted — where an endpoint is
    /// listening is a fact about *this* run, and writing it down would let a stale
    /// file claim a port that nothing is bound to.
    private var bound: [UUID: Int] = [:]
    private var errors: [UUID: String] = [:]
    private let fileURL: URL?
    private let persistQueue = DispatchQueue(label: "com.loom.reverseproxyconfig.persist")

    init(endpoints: [ReverseProxyEndpoint] = [], fileURL: URL? = ReverseProxyConfig.defaultFileURL) {
        self.fileURL = fileURL
        if let fileURL, let saved = Self.load(from: fileURL) {
            self.endpoints = saved
        } else {
            self.endpoints = endpoints
        }
    }

    static var defaultFileURL: URL? {
        LoomPaths.appSupportFile("reverse-proxies.json")
    }

    /// Configured endpoints, in creation order, with this run's bind state.
    func snapshot() -> [ReverseProxyStatus] {
        lock.lock()
        defer { lock.unlock() }
        return endpoints.map {
            ReverseProxyStatus(endpoint: $0, boundPort: bound[$0.id], error: errors[$0.id])
        }
    }

    func endpoint(id: UUID) -> ReverseProxyEndpoint? {
        lock.lock()
        defer { lock.unlock() }
        return endpoints.first { $0.id == id }
    }

    func all() -> [ReverseProxyEndpoint] {
        lock.lock()
        defer { lock.unlock() }
        return endpoints
    }

    /// Add (or replace by id) an endpoint. Persisted.
    func upsert(_ endpoint: ReverseProxyEndpoint) {
        mutate { endpoints in
            if let index = endpoints.firstIndex(where: { $0.id == endpoint.id }) {
                endpoints[index] = endpoint
            } else {
                endpoints.append(endpoint)
            }
        }
    }

    /// Remove an endpoint and forget its bind state. Returns false when there was no
    /// such endpoint.
    func delete(id: UUID) -> Bool {
        var found = false
        mutate { endpoints in
            let before = endpoints.count
            endpoints.removeAll { $0.id == id }
            found = endpoints.count != before
        }
        lock.lock()
        bound[id] = nil
        errors[id] = nil
        lock.unlock()
        return found
    }

    /// Record that an endpoint is listening on `port`, clearing any earlier failure.
    func noteBound(id: UUID, port: Int) {
        lock.lock()
        bound[id] = port
        errors[id] = nil
        lock.unlock()
    }

    /// Record that an endpoint is *not* listening, and why. Kept rather than dropped:
    /// "configured but not listening" is the state a client experiences as connection
    /// refused, and it needs to be readable (`get_proxy_status.reverseProxies`).
    func noteFailure(id: UUID, error: String) {
        lock.lock()
        bound[id] = nil
        errors[id] = error
        lock.unlock()
    }

    func clearBindState() {
        lock.lock()
        bound.removeAll()
        errors.removeAll()
        lock.unlock()
    }

    private func mutate(_ body: (inout [ReverseProxyEndpoint]) -> Void) {
        lock.lock()
        body(&endpoints)
        let updated = endpoints
        if let fileURL { persistQueue.async { Self.persist(updated, to: fileURL) } }
        lock.unlock()
    }

    /// Block until queued writes have run — the quit handler, and any test reading
    /// the file straight after a mutation.
    func flush() {
        persistQueue.sync {}
    }

    // MARK: - Persistence

    private static func persist(_ endpoints: [ReverseProxyEndpoint], to url: URL) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        do {
            let data = try encoder.encode(endpoints)
            try LoomPaths.createSecureDirectory(at: url.deletingLastPathComponent())
            try data.write(to: url, options: .atomic)
            LoomPaths.restrictToOwner(url)
        } catch {
            Log.store.error("Reverse-proxy endpoints persist failed; they may not survive relaunch: \(String(describing: error))")
        }
    }

    private static func load(from url: URL) -> [ReverseProxyEndpoint]? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            return try decoder.decode([ReverseProxyEndpoint].self, from: Data(contentsOf: url))
        } catch {
            // Fail open, loudly: the endpoints vanish, so a dev server pointed at one
            // gets connection-refused and looks like Loom is down.
            Log.store.error("""
            Reverse-proxy endpoints at \(url.path, privacy: .public) could not be read; \
            starting with none — a client pointed at one will get connection refused: \
            \(String(describing: error))
            """)
            return nil
        }
    }
}
