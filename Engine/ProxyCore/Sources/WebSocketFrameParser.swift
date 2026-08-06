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

    /// One step of the parse. `needMore` and `invalid` used to be the same `nil` —
    /// which is how a desynchronised stream became a crash: bytes that don't frame
    /// were indistinguishable from bytes that haven't arrived, so the parser kept
    /// trusting them. They are different answers and the caller acts differently on
    /// each (wait vs. stop parsing this direction for good).
    enum Step: Equatable {
        case frame(Frame, consumed: Int)
        case needMore
        case invalid(String)
    }

    /// Largest payload this parser will accept for one frame. RFC 6455 allows up to
    /// 2^63-1, but a frame is only emitted once it is buffered whole, so an
    /// unbounded length is also an unbounded allocation driven by two bytes on the
    /// wire. Well past anything a real socket sends; a larger claim is read as
    /// desync rather than as a 4 GB frame Loom should sit and wait for.
    static let maxFrameBytes = 64 * 1024 * 1024

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

    /// Why the parser gave up on this direction, once it has. Non-nil means the
    /// byte stream stopped framing as WebSocket — the relay keeps forwarding every
    /// byte, only the capture stops. Never resets: a stream that lost frame
    /// alignment cannot be realigned from bytes alone.
    private(set) var failure: String?

    /// Append newly-arrived bytes and return every frame now fully available.
    mutating func feed(_ bytes: [UInt8]) -> [Frame] {
        guard failure == nil else { return [] }
        buffer.append(contentsOf: bytes)
        var frames: [Frame] = []
        loop: while true {
            switch parseFrame(from: buffer, at: offset) {
            case let .frame(frame, consumed):
                frames.append(frame)
                offset += consumed
            case .needMore:
                break loop
            case let .invalid(reason):
                failure = reason
                // Nothing after a desync is parseable, so hold no bytes for it.
                buffer = []
                offset = 0
                return frames
            }
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

    /// Try to parse one frame starting at `start`.
    ///
    /// Every remaining-bytes check is a **subtraction** (`data.count - index >= n`),
    /// never `data.count >= index + n`: the second form is an addition on attacker-
    /// supplied lengths, and the whole reason this function once trapped. Lengths
    /// are decoded as `UInt64` and only narrowed to `Int` after they're bounded —
    /// the 64-bit path used to shift into `Int`'s sign bit (Swift's `<<` masks
    /// rather than traps), producing a *negative* length that sailed through the
    /// bounds guard and crashed the whole process on `data[index ..< index + length]`.
    private func parseFrame(from data: [UInt8], at start: Int) -> Step {
        guard data.count - start >= 2 else { return .needMore }

        let isFinal = (data[start] & 0x80) != 0
        let opcode = data[start] & 0x0F
        let masked = (data[start + 1] & 0x80) != 0
        var index = start + 2

        let lengthCode = data[start + 1] & 0x7F
        var length64 = UInt64(lengthCode)
        if lengthCode == 126 {
            guard data.count - index >= 2 else { return .needMore }
            length64 = (UInt64(data[index]) << 8) | UInt64(data[index + 1])
            index += 2
        } else if lengthCode == 127 {
            guard data.count - index >= 8 else { return .needMore }
            var value: UInt64 = 0
            for offset in 0 ..< 8 { value = (value << 8) | UInt64(data[index + offset]) }
            // RFC 6455 §5.2: the 64-bit length's most significant bit MUST be 0.
            guard value & 0x8000_0000_0000_0000 == 0 else {
                return .invalid("64-bit frame length has its high bit set (\(value)) — stream is not WebSocket-framed")
            }
            length64 = value
            index += 8
        }
        guard length64 <= UInt64(Self.maxFrameBytes) else {
            return .invalid("frame claims \(length64) payload bytes, over the \(Self.maxFrameBytes)-byte ceiling")
        }
        // RFC 6455 §5.5: a control frame carries ≤125 bytes and is never fragmented.
        // A violation means these bytes aren't a frame header, so keep it a desync
        // rather than a frame nobody can interpret.
        if opcode >= 0x8, length64 > 125 || !isFinal {
            return .invalid("control frame (opcode \(opcode)) is \(isFinal ? "" : "fragmented and ")\(length64) bytes")
        }
        let length = Int(length64)

        var maskKey: [UInt8] = []
        if masked {
            guard data.count - index >= 4 else { return .needMore }
            maskKey = Array(data[index ..< index + 4])
            index += 4
        }

        guard data.count - index >= length else { return .needMore }
        var payload = Array(data[index ..< index + length])
        if masked {
            for offset in 0 ..< payload.count { payload[offset] ^= maskKey[offset % 4] }
        }
        index += length

        return .frame(Frame(isFinal: isFinal, opcode: opcode, payload: Data(payload)), consumed: index - start)
    }
}
