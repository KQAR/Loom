import Foundation

/// Copy / Decode targets for a right-click on wire text.
///
/// Decode applies only to the selected range. An empty selection is not a
/// decode. A truncated `Text` may show less than `displayed`; selecting the
/// whole view still copies/decodes the captured string. A substring is never
/// looked up in a *different* `displayed` (that is how a URL selection of
/// `%20` used to rewrite a header that contained the same token).
struct WireTextMenuPayload: Equatable {
    var copyText: String
    var decodedDisplayed: String?

    static func resolve(displayed: String, viewString: String?, selectedRange: NSRange) -> Self {
        let whole = PercentDecoding.decoded(displayed)
        guard let viewString, selectedRange.length > 0 else {
            return Self(copyText: displayed, decodedDisplayed: nil)
        }
        let view = viewString as NSString
        guard selectedRange.location + selectedRange.length <= view.length else {
            return Self(copyText: displayed, decodedDisplayed: nil)
        }
        let selected = view.substring(with: selectedRange)
        let wholeView = NSRange(location: 0, length: view.length)
        if NSEqualRanges(selectedRange, wholeView) {
            return Self(copyText: displayed, decodedDisplayed: whole)
        }
        if viewString == displayed {
            return Self(copyText: selected, decodedDisplayed: replacing(displayed, range: selectedRange))
        }
        // Partial selection on a truncated view: decode the selected bytes of
        // *this* view. Never `range(of:)` into `displayed` — a URL selection of
        // `%20` would rewrite a header that happened to contain the same token.
        return Self(copyText: selected, decodedDisplayed: replacing(viewString, range: selectedRange))
    }

    private static func replacing(_ displayed: String, range: NSRange) -> String? {
        let ns = displayed as NSString
        guard let decoded = PercentDecoding.decoded(ns.substring(with: range)) else { return nil }
        return ns.replacingCharacters(in: range, with: decoded)
    }
}
