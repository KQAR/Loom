import Foundation
import NIOCore
import NIOEmbedded
import NIOHTTP1
import NIOHTTP2
import NIOPosix
import Testing
@testable import LoomProxyCore
import LoomSharedModels

/// The limits Loom's intercepted HTTP/2 server advertises, and what happens to a
/// stream its codec cannot read.
///
/// Both were found the same way — a real app's home screen hung forever with an
/// empty capture — and both are about the same rule: **a proxy must not be
/// stricter than the origin, and when it is, it must say so instead of going
/// quiet.** Measured against a real API: a 20 KB `Cookie` header answered in 58 ms
/// direct and in 196 ms through Loom's HTTP/1.1 path, while Loom's h2 path hung
/// until the client's own timeout, with no flow, no RST_STREAM and no GOAWAY.
@Suite("HTTP/2 header limits")
struct HTTP2HeaderLimitTests {
    @Test func advertisedHeaderListSizeIsFarAboveSwiftNIOsDefault() {
        // SwiftNIO advertises `HPACKDecoder.defaultMaxHeaderListSize` (16 KB), whose
        // own comment calls the value "somewhat arbitrary". A phone's session
        // cookies reach 15–31 KB, so that default rejects ordinary traffic that
        // works fine without Loom in the path.
        #expect(MITMPipeline.maxHeaderListSize == 1 << 20)
        #expect(MITMPipeline.maxHeaderListSize > 1 << 14,
                "the point of the setting is to be larger than the default it replaces")
    }

    @Test func aCodecErrorIsRecordedAgainstTheHostAndCannotBeSilent() {
        // The reporter's contract, without standing up an h2 peer to break: an error
        // reaching it must land in the one surface that answers "why is this host
        // missing from my capture", carrying what the codec actually said.
        TunneledHostLog.shared.reset()
        let reporter = HTTP2ConnectionErrorReporter(host: "api.example.test", port: 443)
        let channel = EmbeddedChannel()
        try? channel.pipeline.syncOperations.addHandler(reporter)

        channel.pipeline.fireErrorCaught(NIOHTTP2Errors.excessivelyLargeHeaderBlock())

        let recorded = TunneledHostLog.shared.snapshot().hosts
        let entry = recorded.first { $0.host == "api.example.test" }
        #expect(entry?.reason == .protocolError)
        #expect(entry?.detail?.contains("HeaderBlock") == true || entry?.detail?.isEmpty == false,
                "the codec's own words are what separate 'your client sent too much' from 'Loom broke'")
        #expect(entry?.interceptable == false, "no scope change makes an unreadable stream readable")
        #expect(entry?.brokeTheClient == true, "this request did not happen — it is a broken page, not an opaque one")
        _ = try? channel.finish()
        TunneledHostLog.shared.reset()
    }

    @Test func closingIsTheOnlyAnswerAvailableAfterAnUndecodableHeaderBlock() throws {
        // HPACK's dynamic table is per-connection state (RFC 7541 §2.3), so a header
        // block that could not be decoded leaves every later block on that
        // connection undecodable too. RFC 9113 §5.4.1: a connection error is
        // signalled and the connection closed. Staying open is what produced the
        // infinite spinner.
        let channel = EmbeddedChannel()
        try channel.pipeline.syncOperations.addHandler(
            HTTP2ConnectionErrorReporter(host: "api.example.test", port: 443)
        )
        try channel.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 1)).wait()

        channel.pipeline.fireErrorCaught(NIOHTTP2Errors.excessivelyLargeHeaderBlock())
        channel.embeddedEventLoop.run()

        #expect(channel.isActive == false, "the client must learn the request will never be answered")
        _ = try? channel.finish()
        TunneledHostLog.shared.reset()
    }
}
