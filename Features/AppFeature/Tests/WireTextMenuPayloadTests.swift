import Foundation
import Testing
@testable import AppFeature

/// Copy / Decode targets derived from a text view's selected range.
@Suite struct WireTextMenuPayloadTests {
    @Test func emptySelectionIsNotADecode() {
        let payload = WireTextMenuPayload.resolve(
            displayed: "https://example.com/%20",
            viewString: "https://example.com/%20",
            selectedRange: NSRange(location: 0, length: 0)
        )
        #expect(payload.copyText == "https://example.com/%20")
        #expect(payload.decodedDisplayed == nil)
    }

    @Test func selectingTheWholeViewStillCopiesTheCapturedString() {
        let visible = "https://example…/path"
        let captured = "https://example.com/very/long/path"
        let payload = WireTextMenuPayload.resolve(
            displayed: captured,
            viewString: visible,
            selectedRange: NSRange(location: 0, length: (visible as NSString).length)
        )
        #expect(payload.copyText == captured)
        #expect(payload.decodedDisplayed == nil)
    }

    @Test func aSubstringDecodesInPlace() {
        let displayed = "hello%20world"
        let payload = WireTextMenuPayload.resolve(
            displayed: displayed,
            viewString: displayed,
            selectedRange: NSRange(location: 5, length: 3)
        )
        #expect(payload.copyText == "%20")
        #expect(payload.decodedDisplayed == "hello world")
    }

    @Test func aPlainSubstringDoesNotInventADecode() {
        let displayed = "hello%20world"
        let payload = WireTextMenuPayload.resolve(
            displayed: displayed,
            viewString: displayed,
            selectedRange: NSRange(location: 0, length: 5)
        )
        #expect(payload.copyText == "hello")
        #expect(payload.decodedDisplayed == nil)
    }

    @Test func aSelectionDoesNotRewriteADifferentField() {
        let url = "https://example.com/%20path"
        let header = "Bearer%20token"
        let percent = (url as NSString).range(of: "%20")
        let payload = WireTextMenuPayload.resolve(
            displayed: header,
            viewString: url,
            selectedRange: percent
        )
        #expect(payload.copyText == "%20")
        #expect(payload.decodedDisplayed == "https://example.com/ path")
        #expect(payload.decodedDisplayed?.contains("Bearer") != true)
    }
}
