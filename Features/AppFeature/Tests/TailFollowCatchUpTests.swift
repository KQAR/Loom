import AppKit
import Testing

@testable import AppFeature

/// How the list catches up to the bottom after an edit.
///
/// The case that matters is a **display-cap trim**: `CaptureFeature.State.trimSlack`
/// drops 500 rows at once, which makes the document ~12 000 pt shorter, and AppKit
/// shifts the clip view's origin down by the removed height instead of clamping it to
/// the new bottom. The offset is then *past* the end — `remaining` negative — and the
/// old code returned without doing anything. One batch later the origin was a few
/// points short of the new bottom (measured 21 pt, against `isAtBottom`'s half-row
/// 12 pt tolerance), so every later batch read "the operator scrolled away" and
/// `scrollToBottom` was never called again. The list stopped following and the gap
/// grew without bound.
@Suite @MainActor struct TailFollowCatchUpTests {
    private let viewport: CGFloat = 240

    @Test func contentThatShrankUnderTheViewportSnaps() {
        // The trim case: the offset is past the end of the shorter document.
        #expect(RequestTable.Coordinator.tailCatchUp(remaining: -99, viewportHeight: viewport) == .snap)
        #expect(RequestTable.Coordinator.tailCatchUp(remaining: -12_000, viewportHeight: viewport) == .snap)
    }

    @Test func alreadyThereSnaps() {
        // A no-op write rather than a `.glide` that would start a display link with
        // nothing to do.
        #expect(RequestTable.Coordinator.tailCatchUp(remaining: 0, viewportHeight: viewport) == .snap)
    }

    @Test func aShortDistanceGlides() {
        // One row, and the gap the trim leaves behind — both animate.
        #expect(RequestTable.Coordinator.tailCatchUp(remaining: 24, viewportHeight: viewport) == .glide)
        #expect(RequestTable.Coordinator.tailCatchUp(remaining: 21, viewportHeight: viewport) == .glide)
    }

    @Test func tooFarToAnimateSnaps() {
        // `maximumGlideDistance` viewports is the ceiling; past it the animation would
        // be a long blur of rows nobody reads.
        let ceiling = RequestTable.Coordinator.maximumGlideDistance * viewport
        #expect(RequestTable.Coordinator.tailCatchUp(remaining: ceiling, viewportHeight: viewport) == .glide)
        #expect(RequestTable.Coordinator.tailCatchUp(remaining: ceiling + 1, viewportHeight: viewport) == .snap)
    }
}
