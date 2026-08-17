import Foundation
import Testing
@testable import LoomSharedModels

@Suite("Flow diagnostics")
struct FlowDiagnosticsTests {
    @Test func legacyFlowErrorDecodesWithoutInventingAClassification() throws {
        let data = Data(#"{"message":"legacy failure"}"#.utf8)
        let error = try JSONDecoder().decode(FlowError.self, from: data)

        #expect(error.message == "legacy failure")
        #expect(error.code == nil)
        #expect(error.detail == nil)
    }

    @Test func typedTunnelRoundTripsWithItsEvidence() throws {
        let flow = Flow(
            request: CapturedRequest(
                method: "CONNECT", url: "https://api.example.test:443", headers: []
            ),
            startedAt: Date(timeIntervalSince1970: 1),
            outcome: .failed(
                FlowError(
                    "Client rejected Loom's certificate",
                    code: .clientCertificateRejected,
                    detail: "certificate_unknown"
                ),
                at: Date(timeIntervalSince1970: 2),
                partialResponse: nil
            ),
            tunnelDiagnostic: Flow.TunnelDiagnostic(
                host: "api.example.test",
                port: 443,
                reason: .clientHandshakeFailed,
                detail: "certificate_unknown"
            )
        )

        let decoded = try JSONDecoder().decode(
            Flow.self,
            from: JSONEncoder().encode(flow)
        )
        #expect(decoded == flow)
        #expect(decoded.recordKind == Flow.RecordKind.tunnel)
        #expect(decoded.flowError?.code == .clientCertificateRejected)
    }

    @Test func legacyConnectIsProjectedWithoutGuessingItsRelayReason() {
        let flow = Flow(
            request: CapturedRequest(
                method: "CONNECT",
                url: "https://legacy.example.test:8443",
                headers: [HeaderPair(name: "Host", value: "legacy.example.test:8443")]
            ),
            startedAt: Date(),
            outcome: .completed(CapturedResponse(statusCode: 200, headers: []), at: Date())
        )

        #expect(flow.recordKind == Flow.RecordKind.tunnel)
        #expect(flow.effectiveTunnelDiagnostic?.host == "legacy.example.test")
        #expect(flow.effectiveTunnelDiagnostic?.port == 8443)
        #expect(flow.effectiveTunnelDiagnostic?.reason == nil)
    }

    @Test func ordinaryHTTPFlowRemainsAnExchange() {
        let flow = Flow(
            request: CapturedRequest(
                method: "GET", url: "https://api.example.test/v1", headers: []
            ),
            startedAt: Date()
        )
        #expect(flow.recordKind == Flow.RecordKind.exchange)
        #expect(flow.effectiveTunnelDiagnostic == nil)
    }

    @Test func malformedLegacyConnectStillHasTheSameKindAsSQLite() {
        let flow = Flow(
            request: CapturedRequest(
                method: "CONNECT", url: "not a valid URL", headers: []
            ),
            startedAt: Date()
        )
        #expect(flow.recordKind == .tunnel)
        #expect(flow.effectiveTunnelDiagnostic?.host == "not a valid URL")
    }
}
