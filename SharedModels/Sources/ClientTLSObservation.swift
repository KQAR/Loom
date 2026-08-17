import Foundation

public extension TunneledHost {
    /// Session evidence for client-facing TLS attempts to one origin.
    struct ClientTLS: Equatable, Codable, Sendable {
        /// Whether only failures or both outcomes have been observed this session.
        public enum Status: String, Codable, Sendable, CaseIterable {
            case stillFailing
            case mixed
        }

        public enum Result: String, Codable, Sendable, CaseIterable {
            case failed
            case succeeded
        }

        public var failureCount: Int
        public var successCount: Int
        public var lastFailureAt: Date
        public var lastSuccessAt: Date?
        public var lastFailureCode: FlowError.Code
        /// Parsed alert from the latest failure, when the handshake error named one.
        public var lastFailureAlert: TLSClientAlert?

        public var status: Status {
            failureCount > 0 && successCount > 0 ? .mixed : .stillFailing
        }

        public var latestResult: Result {
            guard let lastSuccessAt else { return .failed }
            return lastSuccessAt > lastFailureAt ? .succeeded : .failed
        }

        public init(
            failureCount: Int = 1,
            successCount: Int = 0,
            lastFailureAt: Date,
            lastSuccessAt: Date? = nil,
            lastFailureCode: FlowError.Code,
            lastFailureAlert: TLSClientAlert? = nil
        ) {
            self.failureCount = failureCount
            self.successCount = successCount
            self.lastFailureAt = lastFailureAt
            self.lastSuccessAt = lastSuccessAt
            self.lastFailureCode = lastFailureCode
            self.lastFailureAlert = lastFailureAlert
        }
    }
}
