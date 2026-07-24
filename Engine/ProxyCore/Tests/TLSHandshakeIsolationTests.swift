import NIOCore
import NIOPosix
import NIOSSL
import Testing
@testable import ProxyCore

/// Isolates the CA's server context from the proxy pipeline and URLSession: a
/// plain NIO TLS client (trusting our CA) handshakes directly against a NIO TLS
/// server using `serverContext(for:)`. If this passes, the certificate/key/chain
/// are valid and any failure elsewhere is in the pipeline or the client.
@Suite struct TLSHandshakeIsolationTests {
    @Test func serverContext_completesHandshakeWithNIOClient() throws {
        let ca = try CertificateAuthority.loadOrGenerate(store: InMemoryCAStore())
        let serverCtx = try ca.serverContext(for: "example.test")

        let group = MultiThreadedEventLoopGroup(numberOfThreads: 2)
        defer { try? group.syncShutdownGracefully() }

        let server = try ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { ch in
                ch.pipeline.addHandler(NIOSSLServerHandler(context: serverCtx)).flatMap {
                    ch.pipeline.addHandler(EchoHandler())
                }
            }
            .bind(host: "127.0.0.1", port: 0).wait()
        defer { try? server.close().wait() }
        let port = server.localAddress!.port!

        var clientConfig = TLSConfiguration.makeClientConfiguration()
        let caCert = try NIOSSLCertificate(bytes: Array(ca.caCertificatePEM().utf8), format: .pem)
        clientConfig.trustRoots = .certificates([caCert])
        let clientCtx = try NIOSSLContext(configuration: clientConfig)

        let collector = ResponseCollector(group.next())
        let client = try ClientBootstrap(group: group)
            .channelInitializer { ch in
                do {
                    let tls = try NIOSSLClientHandler(context: clientCtx, serverHostname: "example.test")
                    return ch.pipeline.addHandler(tls).flatMap { ch.pipeline.addHandler(collector) }
                } catch {
                    return ch.eventLoop.makeFailedFuture(error)
                }
            }
            .connect(host: "127.0.0.1", port: port).wait()
        defer { try? client.close().wait() }

        var buffer = client.allocator.buffer(capacity: 4)
        buffer.writeString("ping")
        try client.writeAndFlush(buffer).wait()

        let echoed = try collector.received.futureResult.wait()
        #expect(echoed == "ping", "TLS handshake + echo through our minted leaf must succeed")
    }
}

private final class EchoHandler: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        context.writeAndFlush(data, promise: nil)
    }
}

private final class ResponseCollector: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    let received: EventLoopPromise<String>
    private var acc = ""
    init(_ eventLoop: EventLoop) { received = eventLoop.makePromise() }
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let buffer = unwrapInboundIn(data)
        acc += buffer.getString(at: buffer.readerIndex, length: buffer.readableBytes) ?? ""
        received.succeed(acc)
    }
}
