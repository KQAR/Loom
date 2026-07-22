import Foundation

/// How the request body should change on replay. A single sum type instead of a
/// `body: Data?` + `clearBody: Bool` pair, whose fourth combination (a body *and*
/// clearBody) was a representable illegal state.
public enum BodyOverride: Equatable, Codable, Sendable {
    /// Keep the source flow's body (the default).
    case keep
    /// Send an empty body.
    case clear
    /// Replace with these bytes.
    case replace(Data)
}

/// How a flow should be mutated before being (re)sent. `method`/`url`/headers are
/// optional (nil = "leave as the source flow had it"); the body uses `BodyOverride`.
public struct ReplayOverrides: Equatable, Codable, Sendable {
    public var method: String?
    public var url: String?
    /// Headers to add or overwrite (matched case-insensitively by name).
    public var setHeaders: [HeaderPair]?
    /// Header names to remove (matched case-insensitively).
    public var removeHeaders: [String]?
    public var body: BodyOverride

    public init(
        method: String? = nil,
        url: String? = nil,
        setHeaders: [HeaderPair]? = nil,
        removeHeaders: [String]? = nil,
        body: BodyOverride = .keep
    ) {
        self.method = method
        self.url = url
        self.setHeaders = setHeaders
        self.removeHeaders = removeHeaders
        self.body = body
    }

    public static let none = ReplayOverrides()
}

public struct ProxyStatus: Equatable, Codable, Sendable {
    public var isRunning: Bool
    public var port: Int
    public var capturedCount: Int
    /// Whether observed traffic is being stored as flows. When false the proxy
    /// keeps forwarding (and MITM-decrypting) traffic but records nothing new.
    public var isRecording: Bool

    public init(isRunning: Bool, port: Int, capturedCount: Int, isRecording: Bool = true) {
        self.isRunning = isRunning
        self.port = port
        self.capturedCount = capturedCount
        self.isRecording = isRecording
    }
}

public enum ProxyControlError: Error, Equatable, Sendable {
    case flowNotFound(UUID)
    case invalidURL(String)
    case replayFailed(String)
    case certificateUnavailable(String)
    case ruleNotFound(UUID)
    case invalidRule(String)
}

/// Read side of the engine — what the MCP server and TCA client both query.
public protocol FlowProviding: Sendable {
    func status() async -> ProxyStatus
    func recentFlows(limit: Int) async -> [Flow]
    func flow(id: UUID) async -> Flow?
    /// A live stream of flows as they are captured or updated.
    func flowStream() async -> AsyncStream<Flow>
}

/// Write side of the engine — the differentiator: AI (or the UI) can act.
public protocol FlowReplaying: Sendable {
    /// Re-send an existing flow's request with the given overrides applied,
    /// returning the newly captured flow for the replayed exchange.
    func replay(id: UUID, overrides: ReplayOverrides) async throws -> Flow
}

/// Capture gating: pause/resume storing observed traffic as flows. Pausing
/// never interrupts forwarding — traffic keeps flowing, it just isn't recorded.
public protocol CaptureControlling: Sendable {
    func setRecording(_ recording: Bool) async
}

public typealias ProxyControlling = FlowProviding & FlowReplaying & TLSInterceptControlling & CaptureControlling & RulesControlling
