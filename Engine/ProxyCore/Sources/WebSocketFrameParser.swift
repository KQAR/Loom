import Foundation

/// A read-only, streaming WebSocket frame parser (RFC 6455 §5.2). It observes a
/// copy of one direction's byte stream and emits complete frames for capture —
/// it never re-encodes, so the live relay stays byte-transparent. Handles frames
/// split across reads, extended lengths (16/64-bit), and client masking.
struct WebSocketFrameParser {
    struct Frame: Equatable {
        var isFinal: Bool
        var opcode: UInt8
        var payload: Data
    }

    /// Bytes not yet consumed start at `offset`, not at 0. Consuming a frame moves
    /// the cursor instead of calling `removeFirst`, which is O(remaining) and made a
    /// single read carrying many small frames — the chatty-socket case this parser
    /// exists for — quadratic in that read's byte count.
    private var buffer: [UInt8] = []
    private var offset = 0

    /// Drop the consumed prefix only once it's worth the memmove, so the common
    /// case (a read fully consumed, or a small partial frame left over) doesn't
    /// shift bytes at all.
    private static let compactThreshold = 16 * 1024

    /// Append newly-arrived bytes and return every frame now fully available.
    mutating func feed(_ bytes: [UInt8]) -> [Frame] {
        buffer.append(contentsOf: bytes)
        var frames: [Frame] = []
        while let (frame, consumed) = parseFrame(from: buffer, at: offset) {
            frames.append(frame)
            offset += consumed
        }
        compact()
        return frames
    }

    private mutating func compact() {
        guard offset > 0 else { return }
        if offset == buffer.count {
            buffer.removeAll(keepingCapacity: true)
        } else if offset >= Self.compactThreshold {
            buffer.removeFirst(offset)
        } else {
            return // leave the prefix in place; the cursor already skips it
        }
        offset = 0
    }

    /// Try to parse one frame starting at `start`. Returns the frame and the
    /// number of bytes it consumed, or nil when more bytes are still needed.
    private func parseFrame(from data: [UInt8], at start: Int) -> (Frame, Int)? {
        guard data.count - start >= 2 else { return nil }

        let isFinal = (data[start] & 0x80) != 0
        let opcode = data[start] & 0x0F
        let masked = (data[start + 1] & 0x80) != 0
        var index = start + 2

        var length = Int(data[start + 1] & 0x7F)
        if length == 126 {
            guard data.count >= index + 2 else { return nil }
            length = (Int(data[index]) << 8) | Int(data[index + 1])
            index += 2
        } else if length == 127 {
            guard data.count >= index + 8 else { return nil }
            var value = 0
            for offset in 0 ..< 8 { value = (value << 8) | Int(data[index + offset]) }
            length = value
            index += 8
        }

        var maskKey: [UInt8] = []
        if masked {
            guard data.count >= index + 4 else { return nil }
            maskKey = Array(data[index ..< index + 4])
            index += 4
        }

        guard data.count >= index + length else { return nil }
        var payload = Array(data[index ..< index + length])
        if masked {
            for offset in 0 ..< payload.count { payload[offset] ^= maskKey[offset % 4] }
        }
        index += length

        return (Frame(isFinal: isFinal, opcode: opcode, payload: Data(payload)), index - start)
    }
}
