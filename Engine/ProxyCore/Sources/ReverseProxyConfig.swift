import Foundation
import LoomSharedModels
import Synchronization

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
final class ReverseProxyConfig: Sendable {
    /// All three fields move together under one lock, which is also what makes
    /// `delete` atomic — it used to take the lock twice (once to drop the endpoint,
    /// once to forget its bind state), so a `snapshot()` landing between them saw an
    /// endpoint that no longer existed still carrying a port.
    private struct State {
        var endpoints: [ReverseProxyEndpoint]
        /// Bind results, keyed by endpoint id. Not persisted — where an endpoint is
        /// listening is a fact about *this* run, and writing it down would let a stale
        /// file claim a port that nothing is bound to.
        var bound: [UUID: Int] = [:]
        var errors: [UUID: String] = [:]
    }

    private let state: Mutex<State>
    private let fileURL: URL?
    private let persistQueue = DispatchQueue(label: "com.loom.reverseproxyconfig.persist")

    init(endpoints: [ReverseProxyEndpoint] = [], fileURL: URL? = ReverseProxyConfig.defaultFileURL) {
        self.fileURL = fileURL
        if let fileURL, let saved = Self.load(from: fileURL) {
            self.state = Mutex(State(endpoints: saved))
        } else {
            self.state = Mutex(State(endpoints: endpoints))
        }
    }

    static var defaultFileURL: URL? {
        LoomPaths.appSupportFile("reverse-proxies.json")
    }

    /// Configured endpoints, in creation order, with this run's bind state.
    func snapshot() -> [ReverseProxyStatus] {
        state.withLock { state in
            state.endpoints.map {
                ReverseProxyStatus(endpoint: $0, boundPort: state.bound[$0.id], error: state.errors[$0.id])
            }
        }
    }

    func endpoint(id: UUID) -> ReverseProxyEndpoint? {
        state.withLock { $0.endpoints.first { $0.id == id } }
    }

    func all() -> [ReverseProxyEndpoint] {
        state.withLock { $0.endpoints }
    }

    /// Add (or replace by id) an endpoint. Persisted.
    func upsert(_ endpoint: ReverseProxyEndpoint) {
        mutate { state in
            if let index = state.endpoints.firstIndex(where: { $0.id == endpoint.id }) {
                state.endpoints[index] = endpoint
            } else {
                state.endpoints.append(endpoint)
            }
        }
    }

    /// Remove an endpoint and forget its bind state. Returns false when there was no
    /// such endpoint.
    func delete(id: UUID) -> Bool {
        mutate { state in
            let before = state.endpoints.count
            state.endpoints.removeAll { $0.id == id }
            state.bound[id] = nil
            state.errors[id] = nil
            return state.endpoints.count != before
        }
    }

    /// Record that an endpoint is listening on `port`, clearing any earlier failure.
    func noteBound(id: UUID, port: Int) {
        state.withLock { $0.bound[id] = port; $0.errors[id] = nil }
    }

    /// Record that an endpoint is *not* listening, and why. Kept rather than dropped:
    /// "configured but not listening" is the state a client experiences as connection
    /// refused, and it needs to be readable (`get_proxy_status.reverseProxies`).
    func noteFailure(id: UUID, error: String) {
        state.withLock { $0.bound[id] = nil; $0.errors[id] = error }
    }

    func clearBindState() {
        state.withLock { $0.bound.removeAll(); $0.errors.removeAll() }
    }

    /// Mutate under the lock and enqueue the resulting snapshot for persistence from
    /// *inside* the critical section — that ordering is the invariant this type shares
    /// with `RulesConfig`, not an accident of where the call sits.
    @discardableResult
    private func mutate<T>(_ body: (inout State) -> T) -> T {
        state.withLock { state in
            let result = body(&state)
            let updated = state.endpoints
            if let fileURL { persistQueue.async { Self.persist(updated, to: fileURL) } }
            return result
        }
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
