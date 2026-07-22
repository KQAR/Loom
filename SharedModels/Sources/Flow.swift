import Foundation

/// An ordered HTTP header. Modeled as a list (not a dictionary) so we preserve
/// order and repeated header names exactly as they appeared on the wire.
public struct HeaderPair: Equatable, Codable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    public var value: String

    public init(id: UUID = UUID(), name: String, value: String) {
        self.id = id
        self.name = name
        self.value = value
    }
}

public struct CapturedRequest: Equatable, Codable, Sendable {
    public var method: String
    public var url: String
    public var headers: [HeaderPair]
    public var body: Data?

    public init(method: String, url: String, headers: [HeaderPair], body: Data? = nil) {
        self.method = method
        self.url = url
        self.headers = headers
        self.body = body
    }
}

public struct CapturedResponse: Equatable, Codable, Sendable {
    public var statusCode: Int
    public var headers: [HeaderPair]
    public var body: Data?

    public init(statusCode: Int, headers: [HeaderPair], body: Data? = nil) {
        self.statusCode = statusCode
        self.headers = headers
        self.body = body
    }
}

/// A single captured (or replayed) request/response exchange.
public struct Flow: Identifiable, Equatable, Codable, Sendable {
    public var id: UUID
    public var request: CapturedRequest
    public var response: CapturedResponse?
    public var startedAt: Date
    public var completedAt: Date?
    public var error: String?
    /// Non-nil when this flow was produced by replaying another flow.
    public var replayedFrom: UUID?

    public init(
        id: UUID = UUID(),
        request: CapturedRequest,
        response: CapturedResponse? = nil,
        startedAt: Date,
        completedAt: Date? = nil,
        error: String? = nil,
        replayedFrom: UUID? = nil
    ) {
        self.id = id
        self.request = request
        self.response = response
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.error = error
        self.replayedFrom = replayedFrom
    }

    public var statusCode: Int? { response?.statusCode }

    public var host: String? {
        URLComponents(string: request.url)?.host
    }

    public var durationMS: Int? {
        guard let completedAt else { return nil }
        return Int(completedAt.timeIntervalSince(startedAt) * 1000)
    }
}
