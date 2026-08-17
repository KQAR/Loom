import Foundation
import Testing
@testable import LoomSharedModels

@Suite("TLS client alert parse")
struct TLSClientAlertTests {
    @Test func certificateUnknownIsNotPromotedToARejection() {
        let alert = TLSClientAlert.parse("SSLV3_ALERT_CERTIFICATE_UNKNOWN")
        #expect(alert == .certificateUnknown)
        #expect(alert?.failureCode == .clientCertificateUnknown)
        #expect(alert?.summary.contains("does not prove the leaf is invalid") == true)
    }

    @Test func unknownCAIsARejectionOfTheIssuer() {
        let alert = TLSClientAlert.parse("sslError(UNKNOWN_CA)")
        #expect(alert == .unknownCA)
        #expect(alert?.failureCode == .clientCertificateRejected)
    }

    @Test func badCertificateIsARejectionOfTheLeaf() {
        let alert = TLSClientAlert.parse("ALERT_BAD_CERTIFICATE")
        #expect(alert == .badCertificate)
        #expect(alert?.failureCode == .clientCertificateRejected)
    }

    @Test func unknownCAIsNotSwallowedByCertificateUnknown() {
        #expect(TLSClientAlert.parse("alert_unknown_ca") == .unknownCA)
        #expect(TLSClientAlert.parse("alert_certificate_unknown") == .certificateUnknown)
    }

    @Test func aHandshakeAbortIsNotAnAlert() {
        #expect(TLSClientAlert.parse("eofDuringHandshake") == nil)
        #expect(TLSClientAlert.parse("the client closed the connection") == nil)
    }
}
