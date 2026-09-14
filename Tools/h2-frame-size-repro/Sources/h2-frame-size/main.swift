import Foundation
import NIOCore
import NIOHPACK
import NIOHTTP2
import NIOPosix

// An h2c server and an h2c client, both swift-nio-http2, nothing else in between.
// The client sends one request whose only unusual property is the size of a header
// value, and the *client's own* encoder decides whether it can be put on the wire.

let group = MultiThreadedEventLoopGroup(numberOfThreads: 2)

/// Base64-alphabet bytes, so Huffman coding cannot shrink the value the way a run of
/// one character would — an attestation token or a session cookie looks like this.
func token(_ count: Int) -> String {
    let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/")
    return String((0 ..< count).map { _ in alphabet.randomElement()! })
}

final class Responder: ChannelInboundHandler {
    typealias InboundIn = HTTP2Frame.FramePayload
    typealias OutboundOut = HTTP2Frame.FramePayload

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard case let .headers(headers) = unwrapInboundIn(data), headers.endStream else { return }
        let listSize = headers.headers.reduce(0) { $0 + $1.name.utf8.count + $1.value.utf8.count + 32 }
        print("    server: HEADERS arrived, field list \(listSize) bytes")
        var response = HPACKHeaders()
        response.add(name: ":status", value: "200")
        // `/respond/<n>` asks for an oversized *response* field section — the
        // direction a proxy is in when it answers a client it intercepted.
        if let path = headers.headers.first(name: ":path"), path.hasPrefix("/respond/"),
           let want = Int(path.dropFirst("/respond/".count)) {
            response.add(name: "set-cookie", value: "session=" + token(want))
        }
        context.writeAndFlush(
            wrapOutboundOut(.headers(.init(headers: response, endStream: true)))
        ).whenComplete {
            if case let .failure(error) = $0 {
                print("    server: REFUSED — \(type(of: error)) \(error)")
            }
        }
    }
}

let server = try await ServerBootstrap(group: group)
    .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
    .childChannelInitializer { channel in
        channel.configureHTTP2Pipeline(mode: .server) { stream in
            stream.eventLoop.makeCompletedFuture {
                try stream.pipeline.syncOperations.addHandler(Responder())
            }
        }.map { _ in }
    }
    .bind(host: "127.0.0.1", port: 0)
    .get()
let port = server.localAddress!.port!

func attempt(headerBytes: Int) async {
    print("\(headerBytes) byte header value:")
    do {
        let client = try await ClientBootstrap(group: group).connect(host: "127.0.0.1", port: port).get()
        let multiplexer = try await client.configureHTTP2Pipeline(mode: .client) { $0.close() }.get()
        let stream = try await multiplexer.createStreamChannel { $0.eventLoop.makeCompletedFuture {} }.get()
        var headers = HPACKHeaders()
        headers.add(name: ":method", value: "GET")
        headers.add(name: ":scheme", value: "http")
        headers.add(name: ":path", value: "/")
        headers.add(name: ":authority", value: "127.0.0.1")
        headers.add(name: "x-attestation", value: token(headerBytes))
        try await stream.writeAndFlush(
            HTTP2Frame.FramePayload.headers(.init(headers: headers, endStream: true))
        ).get()
        print("    client: write accepted")
        try? await client.close().get()
    } catch {
        print("    client: REFUSED — \(type(of: error)) \(error)")
    }
}

/// The response direction: the *server* encodes the large field section, which is
/// the shape Loom is in when it answers an intercepted h2 client. Same encoder,
/// same ceiling, and no protocol left to change by then.
func attemptResponse(headerBytes: Int) async {
    print("\(headerBytes) byte response header value:")
    let answered = group.next().makePromise(of: Void.self)
    do {
        let client = try await ClientBootstrap(group: group).connect(host: "127.0.0.1", port: port).get()
        let multiplexer = try await client.configureHTTP2Pipeline(mode: .client) { $0.close() }.get()
        let stream = try await multiplexer.createStreamChannel { stream in
            stream.eventLoop.makeCompletedFuture {
                try stream.pipeline.syncOperations.addHandler(ResponseReader(answered))
            }
        }.get()
        var headers = HPACKHeaders()
        headers.add(name: ":method", value: "GET")
        headers.add(name: ":scheme", value: "http")
        headers.add(name: ":path", value: "/respond/\(headerBytes)")
        headers.add(name: ":authority", value: "127.0.0.1")
        // A deadline, because "no answer at all" is the interesting outcome here and
        // an unbounded wait would report it as a hung tool instead of a finding.
        group.next().scheduleTask(in: .seconds(3)) {
            answered.fail(ChannelError.connectTimeout(.seconds(3)))
        }
        try await stream.writeAndFlush(
            HTTP2Frame.FramePayload.headers(.init(headers: headers, endStream: true))
        ).get()
        try await answered.futureResult.get()
    } catch {
        print("    client: NO RESPONSE — the stream was never answered (\(type(of: error)))")
    }
}

final class ResponseReader: ChannelInboundHandler {
    typealias InboundIn = HTTP2Frame.FramePayload
    let done: EventLoopPromise<Void>
    init(_ done: EventLoopPromise<Void>) { self.done = done }
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        if case let .headers(h) = unwrapInboundIn(data) {
            print("    client: got :status \(h.headers.first(name: ":status") ?? "?")")
            done.succeed(())
        }
    }
    func channelInactive(context: ChannelHandlerContext) { done.fail(ChannelError.eof) }
}

if CommandLine.arguments.contains("--response") {
    for size in [16_000, 30 * 1024] { await attemptResponse(headerBytes: size) }
} else {
    for size in [1024, 7 * 1024, 12 * 1024, 20 * 1024, 30 * 1024] {
        await attempt(headerBytes: size)
    }
}
exit(0)
