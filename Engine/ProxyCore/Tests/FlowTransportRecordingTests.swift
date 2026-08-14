import Testing
import Foundation
import NIOCore
import NIOEmbedded
import NIOHTTP1
@testable import LoomProxyCore
import LoomSharedModels

/// How the connection facts reach a captured flow.
///
/// Two separate defects motivate the two halves. **The client's HTTP version was
/// never recorded at all** — only the upstream hop's, which is always HTTP/1.1
/// because Loom re-originates every exchange — so an h2 client read as HTTP/1.1
/// on every surface Loom has. And **the transport arrives in instalments** (most
/// of it with the head, the encoded size only after the body), which the relay
/// must fold; a relay that overwrote would leave every flow knowing one field.
@Suite struct FlowTransportRecordingTests {
    private let url = URL(string: "https://api.example.test/v1/thing")!

    private func head(_ version: HTTPVersion) -> HTTPRequestHead {
        HTTPRequestHead(version: version, method: .GET, uri: "/v1/thing")
    }

    // MARK: - The client's protocol

    @Test func observe_recordsTheVersionTheClientSpoke() async throws {
        let store = FlowStore()
        let channel = EmbeddedChannel()
        try await channel.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 1)).get()
        defer { _ = try? channel.finish() }

        let observed = CapturedExchange.observe(
            channel: channel, head: head(.http1_1), urlString: url.absoluteString, store: store,
            clientLeg: CapturedExchange.ClientLeg(httpVersion: "HTTP/2", tlsVersion: "TLSv1.3")
        )
        try await Task.sleep(nanoseconds: 50_000_000)

        let flow = try #require(await store.flow(id: observed.id))
        // Stated by the entry point, not derived from the head: the h2↔h1 codec
        // hands this code an HTTP/1.1 head, so deriving would record the shape of
        // the conversion rather than what the client negotiated.
        #expect(flow.request.httpVersion == "HTTP/2")
        // And the client's TLS leg is on the flow from the head-parsed record
        // onward, so a request that then stalls still says how it arrived.
        #expect(flow.transport?.clientTLSVersion == "TLSv1.3")
    }

    @Test func aPlaintextClientLegCarriesNoTransportAtAll() {
        // Nil, not an empty reading: every surface treats an absent transport as
        // "not measured", and a `FlowTransport()` on a cleartext request would
        // claim a connection was inspected and had nothing to say.
        #expect(CapturedExchange.ClientLeg(httpVersion: "HTTP/1.1").transport == nil)
    }

    @Test func httpVersionSpelling_followsTheHead() {
        #expect(HTTPUtil.clientProtocol(.http1_1) == "HTTP/1.1")
        #expect(HTTPUtil.clientProtocol(.http1_0) == "HTTP/1.0")
    }

    // MARK: - Folding the upstream instalments

    @Test func relay_foldsBothTransportInstalmentsOntoTheFlow() async throws {
        let store = FlowStore()
        let flowID = UUID()
        let (stream, continuation) = AsyncThrowingStream<UpstreamResponseEvent, Error>.makeStream()
        let channel = EmbeddedChannel()
        try await channel.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 1)).get()

        let relay = Task {
            await StreamRelay.relay(
                stream: stream, channel: channel, keepAlive: false, flowID: flowID,
                request: CapturedRequest(
                    method: "GET", url: url.absoluteString, httpVersion: "HTTP/2", headers: []
                ),
                startedAt: Date(), sourceApp: nil, sourceDevice: nil, store: store,
                clientTransport: FlowTransport(clientTLSVersion: "TLSv1.3")
            )
        }
        continuation.yield(.transport(FlowTransport(
            remoteAddress: "93.184.216.34:443",
            connectionReused: true,
            upstreamTLS: UpstreamTLSInfo(version: "TLSv1.2"),
            responseContentEncoding: "gzip"
        )))
        continuation.yield(.head(statusCode: 200, httpVersion: "HTTP/1.1", headers: []))
        continuation.yield(.body(Data("done".utf8)))
        continuation.yield(.transport(FlowTransport(responseEncodedBodyBytes: 12)))
        continuation.yield(.end(trailers: nil))
        continuation.finish()
        await relay.value
        _ = try? channel.finish()

        let flow = try #require(await store.flow(id: flowID))
        let transport = try #require(flow.transport)
        // The client leg, the head instalment and the end instalment all survive.
        #expect(transport.clientTLSVersion == "TLSv1.3")
        #expect(transport.remoteAddress == "93.184.216.34:443")
        #expect(transport.connectionReused == true)
        #expect(transport.upstreamTLS?.version == "TLSv1.2")
        #expect(transport.responseContentEncoding == "gzip")
        #expect(transport.responseEncodedBodyBytes == 12)
        // The two versions are separate facts and must stay so — this exact pair
        // (h2 in, HTTP/1.1 out) is the ordinary intercepted case.
        #expect(flow.request.httpVersion == "HTTP/2")
        #expect(flow.response?.httpVersion == "HTTP/1.1")
    }

    @Test func relay_keepsTheClientLegWhenTheExchangeFailsBeforeAnyHead() async throws {
        struct Boom: Error {}
        let store = FlowStore()
        let flowID = UUID()
        let (stream, continuation) = AsyncThrowingStream<UpstreamResponseEvent, Error>.makeStream()
        let channel = EmbeddedChannel()
        try await channel.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 1)).get()

        let relay = Task {
            await StreamRelay.relay(
                stream: stream, channel: channel, keepAlive: false, flowID: flowID,
                request: CapturedRequest(method: "GET", url: url.absoluteString, headers: []),
                startedAt: Date(), sourceApp: nil, sourceDevice: nil, store: store,
                clientTransport: FlowTransport(clientTLSVersion: "TLSv1.3")
            )
        }
        continuation.finish(throwing: Boom())
        await relay.value
        _ = try? channel.finish()

        let flow = try #require(await store.flow(id: flowID))
        #expect(flow.transport?.clientTLSVersion == "TLSv1.3",
                "an exchange that never reached the origin still knows how the client arrived")
        #expect(flow.transport?.remoteAddress == nil)
    }

    // MARK: - The store

    @Test func aLatePendingUpsertCannotEraseATransportThatLanded() async throws {
        // `observe` and the exchange's own upserts run in unordered Tasks, so the
        // head-parsed record can arrive after a streaming one. It carries no
        // upstream transport, and overwriting with it would lose the connection
        // facts for the rest of the flow's life — the same race `sourceApp`
        // already guards against.
        let store = FlowStore()
        let id = UUID()
        let request = CapturedRequest(method: "GET", url: url.absoluteString, headers: [])
        let started = Date()

        await store.upsert(Flow(
            id: id, request: request, startedAt: started,
            outcome: .streaming(CapturedResponse(statusCode: 200, headers: [])),
            transport: FlowTransport(remoteAddress: "1.2.3.4:443")
        ))
        await store.upsert(Flow(id: id, request: request, startedAt: started))

        let flow = try #require(await store.flow(id: id))
        #expect(flow.transport?.remoteAddress == "1.2.3.4:443")
    }
}
