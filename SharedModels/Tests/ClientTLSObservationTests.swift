import Foundation
import Testing
@testable import LoomSharedModels

@Suite("Client TLS observation")
struct ClientTLSObservationTests {
    private let base = Date(timeIntervalSince1970: 1_000)

    @Test func failuresOnlyAreStillFailing() {
        let observation = TunneledHost.ClientTLS(
            failureCount: 29,
            lastFailureAt: base,
            lastFailureCode: .clientCertificateRejected
        )
        #expect(observation.status == .stillFailing)
        #expect(observation.latestResult == .failed)
    }

    @Test func anySuccessAlongsideFailuresIsMixed() {
        let observation = TunneledHost.ClientTLS(
            failureCount: 29,
            successCount: 8,
            lastFailureAt: base,
            lastSuccessAt: base.addingTimeInterval(1),
            lastFailureCode: .clientHandshakeAborted
        )
        #expect(observation.status == .mixed)
        #expect(observation.latestResult == .succeeded)
    }

    @Test func latestResultDoesNotEraseMixedEvidence() {
        let observation = TunneledHost.ClientTLS(
            failureCount: 30,
            successCount: 8,
            lastFailureAt: base.addingTimeInterval(2),
            lastSuccessAt: base.addingTimeInterval(1),
            lastFailureCode: .clientHandshakeAborted
        )
        #expect(observation.status == .mixed)
        #expect(observation.latestResult == .failed)

        let host = TunneledHost(
            host: "api.example.test",
            port: 443,
            firstSeen: base,
            lastSeen: base.addingTimeInterval(2),
            reason: .clientHandshakeFailed,
            clientTLS: observation
        )
        #expect(host.brokeTheClient)
    }
}
