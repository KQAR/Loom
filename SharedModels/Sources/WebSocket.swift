import Foundation

/// One captured WebSocket frame/message on a long-lived WS flow. A WebSocket
/// exchange is modeled as a single `Flow` (the HTTP upgrade request/response)
/// whose `webSocketMessages` grows as frames are relayed in either direction.
public struct WebSocketMessage: Equatable, Codable, Sendable, Identifiable {
    public enum Direction: String, Codable, Sendable {
        case clientToServer
        case serverToClient
    }

    /// WebSocket opcode, mapped to a readable kind (RFC 6455 §5.2).
    public enum Kind: String, Codable, Sendable {
        case text
        case binary
        case ping
        case pong
        case close
        case continuation

        public init(opcode: UInt8) {
            switch opcode {
            case 0x0: self = .continuation
            case 0x1: self = .text
            case 0x2: self = .binary
            case 0x8: self = .close
            case 0x9: self = .ping
            case 0xA: self = .pong
            default: self = .binary
            }
        }
    }

    public var id: UUID
    public var direction: Direction
    public var kind: Kind
    public var payload: Data
    /// FIN bit — false for a fragment continued by later `.continuation` frames.
    public var isFinal: Bool
    public var timestamp: Date

    public init(
        id: UUID = UUID(),
        direction: Direction,
        kind: Kind,
        payload: Data,
        isFinal: Bool = true,
        timestamp: Date
    ) {
        self.id = id
        self.direction = direction
        self.kind = kind
        self.payload = payload
        self.isFinal = isFinal
        self.timestamp = timestamp
    }

    /// UTF-8 rendering for text frames (nil for non-text/undecodable payloads).
    public var textPayload: String? {
        guard kind == .text || kind == .continuation else { return nil }
        return String(data: payload, encoding: .utf8)
    }
}
