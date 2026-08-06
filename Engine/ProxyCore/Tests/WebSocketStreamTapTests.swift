import Testing
import Foundation
@testable import LoomProxyCore

/// The tap skips a direction's HTTP handshake preamble, then surfaces WS frames.
@Suite struct WebSocketStreamTapTests {
    private let frame: [UInt8] = [0x81, 0x02, 0x68, 0x69] // text "hi"

    @Test func noHandshake_parsesFramesImmediately() {
        var tap = WebSocketStreamTap(expectsHandshake: false)
        let frames = tap.consume(frame)
        #expect(frames.count == 1)
        #expect(frames[0].payload == Data("hi".utf8))
    }

    @Test func handshake_skippedThenFramesParsed() {
        var tap = WebSocketStreamTap(expectsHandshake: true)
        let handshake = Array("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\n".utf8)
        let frames = tap.consume(handshake + frame)
        #expect(frames.count == 1, "frames after the 101 handshake should be parsed")
        #expect(frames[0].payload == Data("hi".utf8))
    }

    @Test func handshake_splitAcrossFeeds() {
        var tap = WebSocketStreamTap(expectsHandshake: true)
        #expect(tap.consume(Array("HTTP/1.1 101 Switching Protocols\r\n".utf8)).isEmpty)
        #expect(tap.consume(Array("Upgrade: websocket\r\n\r".utf8)).isEmpty, "boundary not complete yet")
        let frames = tap.consume(Array("\n".utf8) + frame)
        #expect(frames.count == 1)
        #expect(frames[0].payload == Data("hi".utf8))
    }

    /// A parser failure surfaces on the tap so the handler can report it once —
    /// silence here is what made the crash's sibling case (a short frame log) read
    /// like a quiet socket.
    @Test func parserFailure_surfacesAndStopsCapture() {
        var tap = WebSocketStreamTap(expectsHandshake: false)
        #expect(tap.failure == nil)
        _ = tap.consume([0x82, 127, 0xFF, 0, 0, 0, 0, 0, 0, 0])
        #expect(tap.failure != nil)
        #expect(tap.consume(frame).isEmpty, "capture does not resume after a desync")
    }

    /// A stream that never terminates its handshake headers must not buffer forever.
    @Test func unterminatedHandshake_failsInsteadOfBufferingForever() {
        var tap = WebSocketStreamTap(expectsHandshake: true)
        let chunk = [UInt8](repeating: 0x41, count: 8 * 1024)
        for _ in 0 ..< 9 { _ = tap.consume(chunk) } // 72 KiB > the 64 KiB ceiling
        #expect(tap.failure != nil)
    }
}
