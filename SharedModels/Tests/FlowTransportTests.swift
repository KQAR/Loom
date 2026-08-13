import Foundation
import Testing
import LoomSharedModels

/// The connection facts a flow carries, and the two rules that make them
/// trustworthy: a nil field means *unmeasured* (never "no"), and a reading that
/// arrives in two instalments must fold rather than overwrite.
@Suite struct FlowTransportTests {
    // MARK: - Merging

    @Test func merging_keepsWhatTheLaterInstalmentDoesNotCarry() {
        // The shape the relay actually sees: everything the connection knows lands
        // with the head, and the encoded byte count only exists once the body has
        // finished. If the second one replaced rather than merged, every flow
        // would end up knowing nothing but its own body size.
        let atHead = FlowTransport(
            clientTLSVersion: "TLSv1.3",
            remoteAddress: "93.184.216.34:443",
            connectionReused: true,
            upstreamTLS: UpstreamTLSInfo(version: "TLSv1.2"),
            responseContentEncoding: "gzip"
        )
        let atEnd = FlowTransport(responseEncodedBodyBytes: 512)

        let merged = atHead.merging(atEnd)
        #expect(merged.remoteAddress == "93.184.216.34:443")
        #expect(merged.connectionReused == true)
        #expect(merged.clientTLSVersion == "TLSv1.3")
        #expect(merged.upstreamTLS?.version == "TLSv1.2")
        #expect(merged.responseContentEncoding == "gzip")
        #expect(merged.responseEncodedBodyBytes == 512)
    }

    @Test func merging_letsALaterReadingCorrectAnEarlierOne() {
        let base = FlowTransport(connectionReused: false)
        #expect(base.merging(FlowTransport(connectionReused: true)).connectionReused == true)
    }

    @Test func merging_falseIsAValueAndNotAnAbsence() {
        // `connectionReused: false` is the answer "a fresh socket", which explains
        // an outlying TTFB. Treating it as nothing to say would drop exactly the
        // reading someone is looking for.
        let merged = FlowTransport(connectionReused: true).merging(FlowTransport(connectionReused: false))
        #expect(merged.connectionReused == false)
    }

    @Test func isEmpty_distinguishesNothingMeasuredFromSomethingFalse() {
        #expect(FlowTransport().isEmpty)
        #expect(!FlowTransport(connectionReused: false).isEmpty)
    }

    // MARK: - Certificate validity

    @Test func certificateValidity_isJudgedAgainstTheExchangesOwnClock() {
        // A flow read back next month must not report a certificate as expired
        // because it expired *since* — the question is whether the connection that
        // already happened was made against a valid certificate.
        let certificate = PeerCertificateInfo(
            notBefore: Date(timeIntervalSince1970: 1_000),
            notAfter: Date(timeIntervalSince1970: 2_000)
        )
        #expect(certificate.isValid(at: Date(timeIntervalSince1970: 1_500)))
        #expect(!certificate.isValid(at: Date(timeIntervalSince1970: 2_500)))
        #expect(!certificate.isValid(at: Date(timeIntervalSince1970: 500)))
    }

    @Test func certificateValidity_withNoWindowIsNotAFailure() {
        // A certificate Loom could not fully parse still yields a summary; an
        // unmeasured window must not be reported as an invalid one.
        #expect(PeerCertificateInfo(subject: "CN=a.test").isValid(at: Date()))
    }

    // MARK: - Connection setup

    @Test func setupTotal_sumsOnlyWhatWasMeasured() {
        #expect(ConnectionSetup(dnsMS: 12, tcpMS: 20, tlsHandshakeMS: 60).totalMS == 92)
        // A phase that wasn't measured contributes nothing rather than zero — the
        // total is a floor on what setup cost, not a claim to be complete.
        #expect(ConnectionSetup(tcpMS: 20).totalMS == 20)
        #expect(ConnectionSetup().totalMS == nil)
        #expect(ConnectionSetup().isEmpty)
    }

    @Test func setupSurvivesMerging() {
        // It rides the head instalment; the end instalment must not drop it.
        let atHead = FlowTransport(setup: ConnectionSetup(tcpMS: 20))
        let merged = atHead.merging(FlowTransport(requestSendMS: 3))
        #expect(merged.setup?.tcpMS == 20)
        #expect(merged.requestSendMS == 3)
    }

    // MARK: - Body sizes

    @Test func bodyBytes_prefersTheWireSizeOverTheCapturedPrefix() {
        let request = CapturedRequest(
            method: "POST", url: "https://a.test", headers: [],
            body: Data(count: 10), fullBodyBytes: 5_000
        )
        #expect(request.bodyBytes == 5_000, "a capped capture must report what crossed the wire")

        let whole = CapturedRequest(method: "POST", url: "https://a.test", headers: [], body: Data(count: 10))
        #expect(whole.bodyBytes == 10)
        #expect(CapturedRequest(method: "GET", url: "https://a.test", headers: []).bodyBytes == nil)
    }

    // MARK: - Round trip

    @Test func flowSurvivesCoding_withTransportAndClientProtocol() throws {
        let flow = Flow(
            request: CapturedRequest(
                method: "GET", url: "https://a.test/x", httpVersion: "HTTP/2", headers: []
            ),
            startedAt: Date(timeIntervalSince1970: 0),
            transport: FlowTransport(
                remoteAddress: "1.2.3.4:443",
                upstreamTLS: UpstreamTLSInfo(
                    version: "TLSv1.3",
                    certificate: PeerCertificateInfo(issuer: "CN=Test CA")
                )
            )
        )
        let decoded = try JSONDecoder().decode(
            Flow.self, from: JSONEncoder().encode(flow)
        )
        #expect(decoded.request.httpVersion == "HTTP/2")
        #expect(decoded.transport?.remoteAddress == "1.2.3.4:443")
        #expect(decoded.transport?.upstreamTLS?.certificate?.issuer == "CN=Test CA")
    }

    @Test func aFlowWrittenBeforeTheseFieldsExistedStillDecodes() throws {
        // The store holds JSON written by earlier versions; a new non-optional
        // field would have made every one of them undecodable at launch.
        let current = Flow(
            request: CapturedRequest(
                method: "GET", url: "https://a.test", httpVersion: "HTTP/2", headers: []
            ),
            startedAt: Date(timeIntervalSince1970: 0),
            transport: FlowTransport(remoteAddress: "1.2.3.4:443")
        )
        // Take a real encoding and remove the new keys, rather than hand-writing
        // JSON: the outcome enum's wire shape is synthesized, and a literal here
        // would pin this test to a spelling nobody chose.
        var object = try #require(
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(current)) as? [String: Any]
        )
        object["transport"] = nil
        var request = try #require(object["request"] as? [String: Any])
        request["httpVersion"] = nil
        object["request"] = request

        let decoded = try JSONDecoder().decode(
            Flow.self, from: JSONSerialization.data(withJSONObject: object)
        )
        #expect(decoded.request.httpVersion == nil)
        #expect(decoded.transport == nil)
    }
}
