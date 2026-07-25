import Foundation

/// A filter over captured flows — the "find the exchange I care about" predicate
/// shared by the MCP read tools and any embedder.
///
/// Why it exists: an agent asking "what did the app POST to /orders that failed?"
/// could previously only pull the newest N summaries and scan them in its own
/// context. That is expensive (tokens) and *wrong* (a match older than N is
/// invisible, so "no such request" is indistinguishable from "beyond the limit").
/// Filtering belongs next to the store, where it can run over the whole ring and
/// only then apply the limit.
///
/// All set fields AND together; an unset field matches everything. `isEmpty`
/// means "match all", which lets the store take its cheap newest-N path.
public struct FlowQuery: Equatable, Sendable {
    /// Host to match, exactly or as a glob (`*.example.com`) — same semantics as
    /// the SSL-scope host patterns, so one notion of "host pattern" exists.
    public var host: String?
    /// HTTP methods to include, compared case-insensitively.
    public var methods: [String]?
    /// Case-insensitive substring of the absolute URL.
    public var urlContains: String?
    /// Inclusive status-code bounds. An exact status sets both.
    public var statusMin: Int?
    public var statusMax: Int?
    /// Only exchanges that failed: a transport error, or status ≥ 400.
    public var onlyErrors: Bool
    /// Only flows started at or after this instant.
    public var since: Date?
    /// Originating device, by remote IP (see `SourceDevice.groupingKey`).
    public var deviceIP: String?
    /// Originating local app, by bundle id or display name (`SourceApp.groupingKey`).
    public var sourceApp: String?

    public init(
        host: String? = nil,
        methods: [String]? = nil,
        urlContains: String? = nil,
        statusMin: Int? = nil,
        statusMax: Int? = nil,
        onlyErrors: Bool = false,
        since: Date? = nil,
        deviceIP: String? = nil,
        sourceApp: String? = nil
    ) {
        self.host = host
        self.methods = methods
        self.urlContains = urlContains
        self.statusMin = statusMin
        self.statusMax = statusMax
        self.onlyErrors = onlyErrors
        self.since = since
        self.deviceIP = deviceIP
        self.sourceApp = sourceApp
    }

    /// The match-everything query.
    public static let all = FlowQuery()

    /// True when nothing is constrained — callers can skip filtering entirely.
    public var isEmpty: Bool { self == .all }

    public func matches(_ flow: Flow) -> Bool {
        if let since, flow.startedAt < since { return false }
        if let methods, !methods.isEmpty {
            let method = flow.request.method
            guard methods.contains(where: { $0.caseInsensitiveCompare(method) == .orderedSame }) else { return false }
        }
        if let host {
            guard let flowHost = flow.host, SSLScope.matches(pattern: host, host: flowHost) else { return false }
        }
        if let urlContains, !urlContains.isEmpty {
            guard flow.request.url.range(of: urlContains, options: .caseInsensitive) != nil else { return false }
        }
        if onlyErrors {
            // A pending flow is neither an error nor known-good: exclude it, so
            // "show me the failures" never returns something still in flight.
            guard flow.error != nil || (flow.statusCode ?? 0) >= 400 else { return false }
        }
        if let statusMin {
            guard let status = flow.statusCode, status >= statusMin else { return false }
        }
        if let statusMax {
            guard let status = flow.statusCode, status <= statusMax else { return false }
        }
        if let deviceIP {
            guard flow.sourceDevice?.groupingKey == deviceIP else { return false }
        }
        if let sourceApp {
            guard let app = flow.sourceApp,
                  app.groupingKey.caseInsensitiveCompare(sourceApp) == .orderedSame
                  || app.name.caseInsensitiveCompare(sourceApp) == .orderedSame
            else { return false }
        }
        return true
    }
}
