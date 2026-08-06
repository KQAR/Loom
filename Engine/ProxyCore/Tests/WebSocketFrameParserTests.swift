import Foundation
import Testing
@testable import LoomProxyCore
import LoomSharedModels

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

    /// Many small frames in one read, with a partial frame trailing: every complete
    /// frame comes back, and the leftover bytes still join the next read. Guards the
    /// cursor-based consume — a stale offset would drop or mis-slice frames here.
    @Test func manyFramesThenPartialInOneFeed() {
        var parser = WebSocketFrameParser()
        var bytes: [UInt8] = []
        for i in 0 ..< 500 { bytes += [0x81, 0x01, UInt8(i % 26) + 0x61] }
        bytes += [0x81, 0x02, 0x68] // one byte short of "hi"

        let frames = parser.feed(bytes)
        #expect(frames.count == 500)
        #expect(frames[0].payload == Data("a".utf8))
        #expect(frames[499].payload == Data([UInt8(499 % 26) + 0x61]))

        let rest = parser.feed([0x69])
        #expect(rest.count == 1)
        #expect(rest[0].payload == Data("hi".utf8))
    }

    /// Past the compaction threshold the consumed prefix is dropped rather than
    /// tracked by an ever-growing cursor; parsing must survive the re-anchoring.
    @Test func parsingSurvivesBufferCompaction() {
        var parser = WebSocketFrameParser()
        let payload = [UInt8](repeating: 0x7a, count: 1000)
        var total = 0
        for _ in 0 ..< 40 { // 40 KB, crossing the 16 KB compaction threshold
            total += parser.feed([0x82, 126, 0x03, 0xE8] + payload).count
        }
        #expect(total == 40)

        // A frame split across the compaction boundary still reassembles.
        #expect(parser.feed([0x81, 0x05, 0x68, 0x65]).isEmpty)
        let frames = parser.feed([0x6c, 0x6c, 0x6f])
        #expect(frames.count == 1)
        #expect(frames[0].payload == Data("hello".utf8))
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

    // MARK: Malformed input — never trap, stop parsing instead
    //
    // This family exists because a real crash shipped in 0.0.16: a 64-bit length
    // whose high bit was set shifted into `Int`'s sign bit (Swift's `<<` masks
    // rather than traps), the negative length passed the bounds guard, and
    // `data[index ..< index + length]` killed the process from an event-loop
    // thread. The parser reads untrusted network bytes; a trap is never a valid
    // answer here.

    /// The crash: 64-bit length with the MSB set. Must be refused, not slice with a
    /// negative length.
    @Test func sixtyFourBitLengthWithHighBitSet_isRefusedNotFatal() {
        var parser = WebSocketFrameParser()
        let bytes: [UInt8] = [0x82, 127, 0xFF, 0, 0, 0, 0, 0, 0, 0] + [UInt8](repeating: 0, count: 16)
        #expect(parser.feed(bytes).isEmpty)
        #expect(parser.failure != nil)
    }

    /// A plausible-but-absurd 64-bit length (4 GB, high bit clear) is desync too:
    /// waiting for it would buffer the direction forever.
    @Test func sixtyFourBitLengthOverCeiling_isRefused() {
        var parser = WebSocketFrameParser()
        let bytes: [UInt8] = [0x82, 127, 0, 0, 0, 1, 0, 0, 0, 0]
        #expect(parser.feed(bytes).isEmpty)
        #expect(parser.failure?.contains("ceiling") == true)
    }

    /// A 64-bit length within the ceiling is still honoured — the fix must not turn
    /// large legitimate frames into failures.
    @Test func sixtyFourBitLengthWithinCeiling_parsesNormally() {
        let payload = [UInt8](repeating: 0x41, count: 70_000) // > 16-bit, needs the 64-bit form
        var header: [UInt8] = [0x82, 127]
        for shift in stride(from: 56, through: 0, by: -8) { header.append(UInt8((70_000 >> shift) & 0xFF)) }
        var parser = WebSocketFrameParser()
        let frames = parser.feed(header + payload)
        #expect(frames.count == 1)
        #expect(frames[0].payload.count == 70_000)
        #expect(parser.failure == nil)
    }

    /// RFC 6455 §5.5: control frames are ≤125 bytes and never fragmented. A
    /// violation means these bytes aren't a frame header.
    @Test func oversizedControlFrame_isRefused() {
        var parser = WebSocketFrameParser()
        #expect(parser.feed([0x89, 126, 0x01, 0x00]).isEmpty) // ping, 256 bytes
        #expect(parser.failure != nil)
    }

    /// Frames already parsed before the garbage are still returned, and everything
    /// after it is ignored for good — realignment from bytes alone is guesswork.
    @Test func failureKeepsEarlierFramesAndIsPermanent() {
        var parser = WebSocketFrameParser()
        let good: [UInt8] = [0x81, 0x02, 0x68, 0x69]
        let bad: [UInt8] = [0x82, 127, 0xFF, 0, 0, 0, 0, 0, 0, 0]
        let frames = parser.feed(good + bad)
        #expect(frames.count == 1)
        #expect(frames[0].payload == Data("hi".utf8))
        #expect(parser.failure != nil)
        #expect(parser.feed(good).isEmpty, "a failed parser never resumes")
    }

    /// Fuzz the shape that crashed: arbitrary bytes must only ever produce frames or
    /// a failure — never a trap.
    @Test func arbitraryBytesNeverTrap() {
        var seed: UInt64 = 0x5DEE_CE66_D
        func next() -> UInt8 {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return UInt8((seed >> 33) & 0xFF)
        }
        for _ in 0 ..< 200 {
            var parser = WebSocketFrameParser()
            for _ in 0 ..< 8 {
                _ = parser.feed((0 ..< 32).map { _ in next() })
            }
        }
    }
}
