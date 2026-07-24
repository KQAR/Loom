import Foundation
import Testing
@testable import ProxyCore
import SharedModels

@Suite struct WebSocketFrameParserTests {
    /// Server→client text frame "hi": FIN+text, unmasked, len 2.
    @Test func unmaskedTextFrame() {
        var parser = WebSocketFrameParser()
        let frames = parser.feed([0x81, 0x02, 0x68, 0x69])
        #expect(frames.count == 1)
        #expect(frames[0].isFinal)
        #expect(frames[0].opcode == 0x1)
        #expect(frames[0].payload == Data("hi".utf8))
    }

    /// Client→server frames are masked; the parser must unmask.
    @Test func maskedClientFrame() {
        let key: [UInt8] = [0x37, 0xfa, 0x21, 0x3d]
        let payload = Array("hello".utf8)
        let masked = payload.enumerated().map { $0.element ^ key[$0.offset % 4] }
        let bytes: [UInt8] = [0x81, 0x85] + key + masked

        var parser = WebSocketFrameParser()
        let frames = parser.feed(bytes)
        #expect(frames.count == 1)
        #expect(frames[0].payload == Data("hello".utf8))
    }

    /// A frame split across two reads emits only once both halves arrive.
    @Test func frameSplitAcrossFeeds() {
        var parser = WebSocketFrameParser()
        #expect(parser.feed([0x81, 0x05, 0x68, 0x65]).isEmpty, "incomplete frame yields nothing yet")
        let frames = parser.feed([0x6c, 0x6c, 0x6f])
        #expect(frames.count == 1)
        #expect(frames[0].payload == Data("hello".utf8))
    }

    /// Two frames arriving in one read are both returned.
    @Test func multipleFramesInOneFeed() {
        var parser = WebSocketFrameParser()
        let frames = parser.feed([0x81, 0x01, 0x41, 0x8a, 0x00]) // "A" text + empty pong
        #expect(frames.count == 2)
        #expect(frames[0].payload == Data("A".utf8))
        #expect(WebSocketMessage.Kind(opcode: frames[1].opcode) == .pong)
    }

    /// Extended 16-bit length (126 → next two bytes = length).
    @Test func extendedLength126() {
        let payload = [UInt8](repeating: 0x7a, count: 200)
        let bytes: [UInt8] = [0x82, 126, 0x00, 0xC8] + payload // binary, len 200
        var parser = WebSocketFrameParser()
        let frames = parser.feed(bytes)
        #expect(frames.count == 1)
        #expect(frames[0].payload.count == 200)
        #expect(WebSocketMessage.Kind(opcode: frames[0].opcode) == .binary)
    }

    /// Non-final fragment then continuation.
    @Test func fragmentedMessage() {
        var parser = WebSocketFrameParser()
        let frames = parser.feed([0x01, 0x03, 0x66, 0x6f, 0x6f, 0x80, 0x03, 0x62, 0x61, 0x72])
        #expect(frames.count == 2)
        #expect(!frames[0].isFinal)
        #expect(frames[0].opcode == 0x1)
        #expect(frames[1].isFinal)
        #expect(frames[1].opcode == 0x0) // continuation
        #expect(frames[0].payload + frames[1].payload == Data("foobar".utf8))
    }
}
