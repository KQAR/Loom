import Foundation
import NIOCore
import NIOPosix
import Testing
@testable import LoomProxyCore
import LoomSharedModels

/// What an operator reads when the origin could not be reached at all.
///
/// The string is the whole surface: `Flow.error` carries it to `get_recent_flows`,
/// `get_flow_detail`, HAR and the Inspector, and Loom writes it into the 502 it hands
/// the client. Before this, every one of those said
/// `The operation couldn’t be completed. (NIOPosix.NIOConnectionError error 1.)` —
/// identical for a refused port, an unresolvable name and a black hole.
///
/// `NIOConnectionError`'s initialiser is `fileprivate`, so the refused case is
/// exercised against a real socket rather than a fabricated error. That is the right
/// way round anyway: what is being pinned is that the errno actually survives the trip
/// out of NIO and into the message.
@Suite("Upstream connection error", .timeLimit(.minutes(1)))
final class UpstreamConnectionErrorTests {
    private let group = MultiThreadedEventLoopGroup(numberOfThreads: 2)

    deinit { shutdownBlocking(group) }

    /// A port with nothing listening: bind one, read its number, close it.
    private func closedPort() throws -> Int {
        let channel = try ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .bind(host: "127.0.0.1", port: 0).wait()
        let port = channel.localAddress!.port!
        try channel.close().wait()
        return port
    }

    @Test func aRefusedConnectionNamesTheAddressAndTheErrno() async throws {
        let port = try closedPort()
        let forwarder = NIOStreamingForwarder(group: group)
        await #expect(throws: (any Error).self) {
            try await forwarder.forward(
                method: "GET", url: URL(string: "http://127.0.0.1:\(port)/x")!, headers: [], body: nil
            )
        }
        var message = ""
        do {
            _ = try await forwarder.forward(
                method: "GET", url: URL(string: "http://127.0.0.1:\(port)/x")!, headers: [], body: nil
            )
        } catch {
            message = error.localizedDescription
        }
        #expect(message.contains("Could not connect to 127.0.0.1:\(port)"), "\(message)")
        #expect(message.contains("ECONNREFUSED"), "\(message)")
        // The address that refused, not just the name asked for: "refused on ::1 but
        // not on 127.0.0.1" is a real shape and otherwise invisible.
        #expect(message.contains("127.0.0.1:\(port):"), "\(message)")
    }

    /// A name that cannot resolve is a different sentence from a port that refuses —
    /// telling them apart is most of why this type exists.
    @Test func anUnresolvableHostSaysSo() async throws {
        let forwarder = NIOStreamingForwarder(group: group)
        var message = ""
        do {
            _ = try await forwarder.forward(
                method: "GET",
                url: URL(string: "http://loom-does-not-exist.invalid/x")!, headers: [], body: nil
            )
        } catch {
            message = error.localizedDescription
        }
        #expect(message.contains("Could not connect to loom-does-not-exist.invalid:80"), "\(message)")
        #expect(message.contains("resolve"), "\(message)")
    }

    /// The timeout branch is reachable without a socket, so it is pinned directly.
    @Test func aConnectTimeoutReportsItsDuration() {
        let reason = UpstreamConnectionError.reason(ChannelError.connectTimeout(.seconds(3)))
        #expect(reason == "timed out after 3.0s")
    }

    /// Anything that is not a failure to *reach* the origin passes through untouched:
    /// a connection that died mid-exchange demonstrably happened, and prefixing it
    /// with "could not connect" would be a wrong answer rather than a thin one.
    @Test func aMidExchangeFailureIsNotWrapped() {
        let original = ForwarderError.connectionClosed
        let wrapped = UpstreamConnectionError.wrapping(original, host: "a.com", port: 443)
        #expect(wrapped is ForwarderError)
    }
}
