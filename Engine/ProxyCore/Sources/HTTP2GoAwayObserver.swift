import Foundation
import NIOCore
import NIOHTTP2

/// The GOAWAY error code Loom's own h2 codec sent, for the report that otherwise
/// cannot say what went wrong.
///
/// **Why this is a byte parser and not an `HTTP2Frame` read.** `NIOHTTP2Handler`
/// collapses about forty distinct `InternalError.codecError(code:)` throws into one
/// `NIOHTTP2Errors.unableToParseFrame()`; the code survives only in the GOAWAY frame
/// it writes. That write is issued *by* `NIOHTTP2Handler` and travels outbound toward
/// the pipeline **head**, so a handler at the tail — where `HTTP2Frame` values exist —
/// never sees it. Head-side of the codec the frame is already serialized, so reading
/// the code means reading the wire format. Nine header bytes and two fields.
///
/// Diagnostic only: it records and forwards, and nothing branches on what it saw.
final class HTTP2GoAwayCode: @unchecked Sendable {
    /// Event-loop confined like the handlers that touch it.
    var code: HTTP2ErrorCode?
}

/// Sits between the TLS handler and `NIOHTTP2Handler`, so the bytes it sees on the way
/// out are the codec's own frames.
// @unchecked Sendable: event-loop confined, no lock — see ProxyCore/CLAUDE.md
// § Sendable escape hatches for what that forbids inside a `Task {}`.
final class HTTP2GoAwayObserver: ChannelOutboundHandler, RemovableChannelHandler, @unchecked Sendable {
    typealias OutboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    /// RFC 9113 §6.8 — GOAWAY is frame type 0x7.
    private static let goAwayType: UInt8 = 0x7
    /// §4.1: length (24) | type (8) | flags (8) | R (1) + stream id (31).
    private static let frameHeaderLength = 9

    private let box: HTTP2GoAwayCode

    init(box: HTTP2GoAwayCode) {
        self.box = box
    }

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        record(Self.unwrapOutboundIn(data))
        context.write(data, promise: promise)
    }

    /// Walk the frames in one write and keep the last GOAWAY's code.
    ///
    /// **Bounded by subtraction, never by addition on a wire length** — the rule the
    /// WebSocket frame parser exists to state (AGENTS.md § WebSocket). These are
    /// Loom's *own* bytes, so a malformed one is impossible today; parsing them the
    /// same way as untrusted input costs nothing and means the next person to point
    /// this at a peer's stream does not have to notice.
    private func record(_ buffer: ByteBuffer) {
        var bytes = buffer
        while bytes.readableBytes >= Self.frameHeaderLength {
            guard let header = bytes.getBytes(at: bytes.readerIndex, length: Self.frameHeaderLength) else { return }
            let length = Int(header[0]) << 16 | Int(header[1]) << 8 | Int(header[2])
            let type = header[3]
            guard bytes.readableBytes - Self.frameHeaderLength >= length else { return }
            if type == Self.goAwayType, length >= 8 {
                let payloadStart = bytes.readerIndex + Self.frameHeaderLength
                if let raw = bytes.getInteger(at: payloadStart + 4, as: UInt32.self) {
                    box.code = HTTP2ErrorCode(networkCode: Int(raw))
                }
            }
            bytes.moveReaderIndex(forwardBy: Self.frameHeaderLength + length)
        }
    }
}
