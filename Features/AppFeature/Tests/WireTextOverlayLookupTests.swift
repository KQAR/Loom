import AppKit
import Testing
@testable import AppFeature

/// How the decode overlay finds the `NSTextView` SwiftUI put under it.
///
/// The lookup walks ancestors' whole subtrees, and it runs on every SwiftUI
/// update and every layout pass — so a Headers pane with N rows ran it N times
/// per layout, and a *miss* used to climb to the window root and enumerate
/// every view in the window. Two properties keep that bounded: the answer is
/// cached and re-validated rather than re-derived, and the climb stops.
@Suite @MainActor struct WireTextOverlayLookupTests {
    private let frame = NSRect(x: 0, y: 0, width: 200, height: 40)

    private func container() -> (NSView, NSTextView, WireTextHostOverlay.Sentinel) {
        let container = NSView(frame: frame)
        let textView = NSTextView(frame: frame)
        let sentinel = WireTextHostOverlay.Sentinel(frame: frame)
        container.addSubview(textView)
        container.addSubview(sentinel)
        return (container, textView, sentinel)
    }

    @Test func theCoveringTextViewIsASibling() {
        let (_, textView, sentinel) = container()
        #expect(sentinel.coveringTextView() === textView)
    }

    @Test func aTextViewThatBarelyOverlapsIsNotStolen() {
        // Both sides must mostly cover each other: a full-pane overlay must not
        // claim a small cell that happens to sit inside it.
        let pane = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 400))
        let cell = NSTextView(frame: NSRect(x: 0, y: 0, width: 40, height: 20))
        let sentinel = WireTextHostOverlay.Sentinel(frame: NSRect(x: 0, y: 0, width: 400, height: 400))
        pane.addSubview(cell)
        pane.addSubview(sentinel)
        #expect(sentinel.coveringTextView() == nil)
    }

    @Test func theAnswerIsCachedRatherThanRewalked() {
        let (_, textView, sentinel) = container()
        #expect(sentinel.coveringTextView() === textView)
        // Detached from the hierarchy the search cannot reach it any more, so a
        // second call that still answers is the cache answering. Its geometry
        // is unchanged, which is what the cache re-validates against.
        textView.removeFromSuperview()
        #expect(sentinel.coveringTextView() === textView)
    }

    @Test func aCachedAnswerThatNoLongerCoversIsDropped() {
        let (_, textView, sentinel) = container()
        #expect(sentinel.coveringTextView() === textView)
        textView.removeFromSuperview()
        textView.frame = NSRect(x: 0, y: 0, width: 4, height: 4)
        #expect(sentinel.coveringTextView() == nil)
    }

    @Test func theClimbStopsBeforeTheWindowRoot() {
        // The text view Loom wants is the sibling the overlay was attached to,
        // a container or two up. Anything further is a miss, and a miss must
        // cost a bounded walk rather than every view above it.
        let root = NSView(frame: frame)
        let textView = NSTextView(frame: frame)
        root.addSubview(textView)
        var parent = root
        for _ in 0 ..< 6 {
            let child = NSView(frame: frame)
            parent.addSubview(child)
            parent = child
        }
        let sentinel = WireTextHostOverlay.Sentinel(frame: frame)
        parent.addSubview(sentinel)
        #expect(sentinel.coveringTextView() == nil)
    }
}
