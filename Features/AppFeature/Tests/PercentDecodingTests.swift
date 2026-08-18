import Foundation
import Testing
@testable import AppFeature

/// Percent-decoding of captured wire text.
///
/// The two things worth pinning: `+` is not a space (that is form-urlencoded,
/// and it would corrupt base64), and a string that is not encoded — or will not
/// decode — returns nil so a context menu can disable the action rather than
/// no-op it.
@Suite struct PercentDecodingTests {
    @Test func aPercentEncodedValueDecodes() {
        #expect(PercentDecoding.decoded("hello%20world") == "hello world")
        #expect(PercentDecoding.decoded("%2Fa%2Fb") == "/a/b")
    }

    @Test func plusIsLeftAlone() {
        #expect(PercentDecoding.decoded("ab+cd/ef=") == nil)
    }

    @Test func plainTextIsNotAnAction() {
        #expect(PercentDecoding.decoded("Bearer abc") == nil)
        #expect(PercentDecoding.decoded("") == nil)
    }

    @Test func malformedPercentSequencesAreNotGuessedAt() {
        #expect(PercentDecoding.decoded("%ZZ") == nil)
        #expect(PercentDecoding.decoded("100%") == nil)
    }

    @Test func onePassLeavesADoubleEncodedValueStillEncoded() {
        // `%2520` is a percent-encoded `%20`. One pass is the menu's unit of
        // work; applying it again is how an operator peels the second layer.
        #expect(PercentDecoding.decoded("%2520") == "%20")
        #expect(PercentDecoding.decoded("%20") == " ")
    }
}
