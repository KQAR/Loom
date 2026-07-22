import XCTest
@testable import ProxyCore

/// The tap skips a direction's HTTP handshake preamble, then surfaces WS frames.
final class WebSocketStreamTapTests: XCTestCase {
    private let frame: [UInt8] = [0x81, 0x02, 0x68, 0x69] // text "hi"

    func test_noHandshake_parsesFramesImmediately() {
        var tap = WebSocketStreamTap(expectsHandshake: false)
        let frames = tap.consume(frame)
        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(frames[0].payload, Data("hi".utf8))
    }

    func test_handshake_skippedThenFramesParsed() {
        var tap = WebSocketStreamTap(expectsHandshake: true)
        let handshake = Array("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\n".utf8)
        let frames = tap.consume(handshake + frame)
        XCTAssertEqual(frames.count, 1, "frames after the 101 handshake should be parsed")
        XCTAssertEqual(frames[0].payload, Data("hi".utf8))
    }

    func test_handshake_splitAcrossFeeds() {
        var tap = WebSocketStreamTap(expectsHandshake: true)
        XCTAssertTrue(tap.consume(Array("HTTP/1.1 101 Switching Protocols\r\n".utf8)).isEmpty)
        XCTAssertTrue(tap.consume(Array("Upgrade: websocket\r\n\r".utf8)).isEmpty, "boundary not complete yet")
        let frames = tap.consume(Array("\n".utf8) + frame)
        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(frames[0].payload, Data("hi".utf8))
    }
}
