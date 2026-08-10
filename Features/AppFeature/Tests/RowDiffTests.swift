import Foundation
import LoomSharedModels
import Testing

@testable import AppFeature

/// The request table's update diff.
///
/// Worth testing precisely because its failure mode is quiet: a wrong answer here does
/// not crash, it leaves `NSTableView` believing rows are at indices they are not — so
/// cells render against the wrong flow, and the next edit is computed against that. A
/// full `reloadData()` is always *correct*; this exists to avoid paying it ten times a
/// second, so every case that isn't certain must fall back to it.
@Suite struct RowDiffTests {
    private func flow(_ n: Int, status: Int? = 200) -> Flow {
        Flow(
            id: UUID(),
            request: CapturedRequest(method: "GET", url: "https://api.test/\(n)", headers: []),
            startedAt: Date(timeIntervalSince1970: TimeInterval(n)),
            outcome: status.map {
                .completed(CapturedResponse(statusCode: $0, headers: []), at: Date(timeIntervalSince1970: TimeInterval(n)))
            } ?? .pending
        )
    }

    private func completed(_ flow: Flow, status: Int) -> Flow {
        var copy = flow
        copy.outcome = .completed(CapturedResponse(statusCode: status, headers: []), at: Date())
        return copy
    }

    // MARK: The shapes the capture actually produces

    @Test func noChangeIsNoWork() {
        let rows = (0 ..< 5).map { flow($0) }
        #expect(RowDiff(from: rows, to: rows).isNone)
    }

    /// The common case: a batch lands at the tail.
    @Test func appendingRowsIsAnEdit() {
        let old = (0 ..< 5).map { flow($0) }
        let new = old + (5 ..< 8).map { flow($0) }
        #expect(RowDiff(from: old, to: new) == .edit(removedFromFront: 0, appended: 3))
    }

    /// The window cap trimming the head.
    @Test func trimmingTheHeadIsAnEdit() {
        let old = (0 ..< 10).map { flow($0) }
        let new = Array(old.dropFirst(3))
        #expect(RowDiff(from: old, to: new) == .edit(removedFromFront: 3, appended: 0))
    }

    /// Steady state at the cap: rows come off the head as they arrive at the tail.
    @Test func trimAndAppendTogether() {
        let old = (0 ..< 10).map { flow($0) }
        let new = Array(old.dropFirst(2)) + (10 ..< 14).map { flow($0) }
        #expect(RowDiff(from: old, to: new) == .edit(removedFromFront: 2, appended: 4))
    }

    /// An exchange progressing (pending → completed) changes a row's *content* and not
    /// the list's structure — so the diff reports no structural work, and the row's new
    /// values reach the screen through the unconditional viewport refresh instead.
    ///
    /// That split is the point: finding changed rows here would mean a value comparison
    /// per retained flow on every capture batch, which scales with the capture. The
    /// refresh scales with the viewport.
    @Test func anInPlaceChangeIsNotStructuralWork() {
        let old = (0 ..< 5).map { flow($0, status: nil) }
        var new = old
        new[2] = completed(old[2], status: 500)
        #expect(RowDiff(from: old, to: new) == .none)
    }

    // MARK: The property that actually matters

    /// Applying a diff to the old rows must reproduce the new rows — whichever case it
    /// picked.
    ///
    /// This is the real invariant, and asserting *which case fires* is not: `reload` is
    /// always a correct answer, so a test demanding it pins an implementation detail
    /// rather than the behaviour. It caught the author here — a reversal was expected to
    /// reload and is in fact a legitimate head-trim-plus-append (its one surviving row
    /// really is the same flow), which the simulation shows is applied correctly.
    private func applied(_ diff: RowDiff, to old: [Flow], expecting new: [Flow]) -> [Flow] {
        switch diff {
        case .none:
            return old
        case .reload:
            return new
        case let .edit(removedFromFront, appended):
            var rows = Array(old.dropFirst(removedFromFront))
            rows += new.suffix(appended)
            return rows
        }
    }

    /// The structure a diff produces must leave the table with the **right number of
    /// rows, holding the right flows in order** — up to content, which the viewport
    /// refresh supplies. Compared by id for exactly that reason.
    private func check(_ old: [Flow], _ new: [Flow], _ comment: Comment) {
        let result = applied(RowDiff(from: old, to: new), to: old, expecting: new)
        #expect(result.map(\.id) == new.map(\.id), comment)
    }

    @Test func everyShapeAppliesToTheNewRows() {
        let base = (0 ..< 8).map { flow($0) }
        check(base, base, "unchanged")
        check(base, base + (8 ..< 11).map { flow($0) }, "append")
        check(base, Array(base.dropFirst(3)), "head trim")
        check(base, Array(base.dropFirst(2)) + (8 ..< 12).map { flow($0) }, "trim + append")
        check(base, Array(base.reversed()), "reversal")
        check(base, (100 ..< 108).map { flow($0) }, "a different list")
        check(base, [], "cleared")
        check([], base, "first rows")

        var middleRemoved = base
        middleRemoved.remove(at: 3)
        check(base, middleRemoved, "removal from the middle")

        var mutated = base
        mutated[5] = completed(base[5], status: 500)
        check(base, mutated, "in-place change")

        var trimmedAndMutated = Array(base.dropFirst(2))
        trimmedAndMutated[1] = completed(trimmedAndMutated[1], status: 503)
        check(base, trimmedAndMutated, "trim + in-place change")
    }

    // MARK: Everything else must fall back

    /// A category tap or a needle is a different list, not an edit of this one.
    @Test func aDifferentListReloads() {
        let old = (0 ..< 5).map { flow($0) }
        let new = (100 ..< 105).map { flow($0) }
        #expect(RowDiff(from: old, to: new).isReload)
    }

    /// A shrinking list that still shares its first row is not a shape the capture
    /// produces. Rather than invent an edit for it, rebuild — the count is the one thing
    /// structure must get right, and guessing it is how rows end up drawn at indices
    /// they aren't at.
    @Test func aShrinkingListReloads() {
        let old = (0 ..< 6).map { flow($0) }
        var new = old
        new.remove(at: 3)
        #expect(RowDiff(from: old, to: new).isReload)
    }

    /// The alignment search is bounded, so a list whose anchor sits past the bound is a
    /// different list as far as this is concerned — an honest fallback rather than an
    /// O(capture) walk to conclude nothing.
    @Test func anAnchorPastTheSearchBoundReloads() {
        let old = (0 ..< (RowDiff.maxAlignmentSearch + 50)).map { flow($0) }
        let new = Array(old.dropFirst(RowDiff.maxAlignmentSearch + 10))
        #expect(RowDiff(from: old, to: new).isReload)
    }

    @Test func clearingReloads() {
        #expect(RowDiff(from: (0 ..< 5).map { flow($0) }, to: []).isReload)
    }

    @Test func firstRowsReload() {
        #expect(RowDiff(from: [], to: (0 ..< 5).map { flow($0) }).isReload)
    }

    @Test func emptyToEmptyIsNoWork() {
        #expect(RowDiff(from: [], to: []).isNone)
    }

    /// A trim that dropped every previously-visible row leaves no anchor to align on.
    @Test func aWholesaleReplacementReloads() {
        let old = (0 ..< 5).map { flow($0) }
        let new = (5 ..< 10).map { flow($0) }
        #expect(RowDiff(from: old, to: new).isReload)
    }
}

/// The tail-follow's one decision, taken away from AppKit so the occluded case can be
/// stated rather than measured off geometry that is deliberately no longer maintained.
@Suite @MainActor struct TailFollowDecisionTests {
    private typealias Decide = RequestTable.Coordinator

    @Test func onScreen_theGeometryDecides() {
        #expect(Decide.shouldFollowTail(windowVisible: true, atBottom: true, gliding: false, current: false))
        #expect(!Decide.shouldFollowTail(windowVisible: true, atBottom: false, gliding: false, current: true))
    }

    /// A glide is behind the bottom by construction, so it counts as being there.
    @Test func aGlideInFlightCountsAsAtBottom() {
        #expect(Decide.shouldFollowTail(windowVisible: true, atBottom: false, gliding: true, current: false))
    }

    /// Occluded, the offset is not kept at the bottom — that is the saving — so the
    /// viewport falls behind and geometry would answer "not at the bottom" for a reader
    /// who never scrolled. The answer is frozen instead, in both directions.
    @Test func occluded_theAnswerIsFrozen() {
        #expect(Decide.shouldFollowTail(windowVisible: false, atBottom: false, gliding: false, current: true))
        #expect(!Decide.shouldFollowTail(windowVisible: false, atBottom: true, gliding: true, current: false))
    }
}

private extension RowDiff {
    var isNone: Bool { if case .none = self { true } else { false } }
    var isReload: Bool { if case .reload = self { true } else { false } }
}
