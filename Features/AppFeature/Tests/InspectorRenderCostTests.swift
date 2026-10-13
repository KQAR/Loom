import AppKit
import Foundation
import Testing
@testable import AppFeature

/// The inspector re-renders on every capture batch touching the selected flow, every
/// find keystroke, every preference the body reports up. What it derives from a body
/// must not be re-derived each time, and a streaming body must not be re-laid-out
/// from scratch each time it grows.
@MainActor
@Suite("Inspector render cost")
struct InspectorRenderCostTests {
    @Test func aMemoComputesOncePerKey() {
        let memo = RenderMemo<BodyMemoKey, String?>()
        let id = UUID()
        var builds = 0
        let make: () -> String? = { builds += 1; return "body" }
        _ = memo.value(for: BodyMemoKey(flowID: id, bytes: 4), make)
        _ = memo.value(for: BodyMemoKey(flowID: id, bytes: 4), make)
        #expect(builds == 1, "an unchanged body must not be decoded again")
        _ = memo.value(for: BodyMemoKey(flowID: id, bytes: 8), make)
        #expect(builds == 2, "a body that grew must be")
    }

    @Test func aGrowingDocumentIsExtendedNotReplaced() throws {
        let textView = NSTextView()
        textView.string = "HTTP/1.1 200 OK\r\n\r\nfirst"
        let storage = try #require(textView.textStorage)
        #expect(CodeTextView.appendGrowth(of: textView.string, to: textView.string + " second", in: textView))
        #expect(storage.string == "HTTP/1.1 200 OK\r\n\r\nfirst second")

        // Not a growth of what is on screen: the caller replaces the whole document.
        #expect(!CodeTextView.appendGrowth(of: "first", to: "other", in: textView))
        #expect(!CodeTextView.appendGrowth(of: "", to: "anything", in: textView))
        #expect(!CodeTextView.appendGrowth(of: "same", to: "same", in: textView))
    }

    @Test func aMultibyteBoundaryAppendsWholeCharacters() throws {
        let textView = NSTextView()
        textView.string = "€"
        #expect(CodeTextView.appendGrowth(of: "€", to: "€✓", in: textView))
        #expect(textView.string == "€✓")
    }
}
