import AppKit
import ComposableArchitecture
import Foundation
import LoomSharedModels
import SwiftUI
import Testing

@testable import AppFeature

/// Syncing the table's selection must cost the viewport, not the capture.
///
/// `Coordinator.update` runs on every capture batch — ten times a second — and the
/// selection sync inside it used to open with `rows.firstIndex { $0.id == id }`: a
/// linear walk of the window, which at `FlowLimits.windowRows` is 20 000 id comparisons
/// to conclude, almost always, that nothing moved. Every other lookup in `RequestTable`
/// already refuses that shape (`ordinal(of:)` takes an O(1) `index(id:)`; `RowDiff`
/// bounds its alignment search) — this one was the exception, and it was on the hot path.
///
/// The fast path asks the *table* where its selection is, which is O(1) and correct at
/// steady state because `apply` runs first and `NSTableView` shifts its own selection
/// index across `removeRows`/`insertRows`. The scan survives for the cases where that
/// fails — a `.reload`, or a selection the store moved — and those are gestures, not
/// traffic.
@MainActor
@Suite final class RequestTableSelectionTests {
    /// Everything a `Coordinator` needs to be driven without a window.
    ///
    /// No window on purpose: `update` reads `isWindowVisible` and skips the glide when
    /// there isn't one, so the data path under test runs with nothing on a display link
    /// racing it. The structural edit and the selection sync both still run — those are
    /// applied whether or not anyone can see them, which is the property being measured.
    @MainActor
    private final class Harness {
        let table = NSTableView()
        let scrollView = NSScrollView()
        let coordinator: RequestTable.Coordinator
        /// What the coordinator writes back through its bindings.
        let state = Box()

        @MainActor
        final class Box {
            var selection: Flow.ID?
            var followTail = true
        }

        init() {
            let state = self.state
            coordinator = RequestTable.Coordinator(
                selection: Binding(get: { state.selection }, set: { state.selection = $0 }),
                followTail: Binding(get: { state.followTail }, set: { state.followTail = $0 }),
                onReplay: { _ in }, onCopyCurl: { _ in }, onAddRule: { _, _ in },
                onExcludeHost: { _ in }
            )
            table.rowHeight = RequestTable.rowHeight
            table.addTableColumn(NSTableColumn(identifier: RequestTable.Column.path.identifier))
            table.dataSource = coordinator
            table.delegate = coordinator
            scrollView.documentView = table
            coordinator.attach(scrollView: scrollView, table: table)
        }

        // No `deinit { coordinator.detach() }`: `detach` is main-actor isolated and a
        // `deinit` is not, and there is nothing to tear down here anyway — the glide
        // never starts without a window, and `NotificationCenter` drops a deallocated
        // observer's registrations itself.
    }

    private func flow(_ n: Int) -> Flow {
        Flow(
            id: UUID(),
            request: CapturedRequest(method: "GET", url: "https://api.test/\(n)", headers: []),
            startedAt: Date(timeIntervalSince1970: TimeInterval(n)),
            outcome: .completed(
                CapturedResponse(statusCode: 200, headers: []),
                at: Date(timeIntervalSince1970: TimeInterval(n) + 0.1)
            )
        )
    }

    private func capture(_ rows: [Flow]) -> IdentifiedArrayOf<Flow> {
        IdentifiedArrayOf(uniqueElements: rows)
    }

    // MARK: Correctness — the fast path must not change what gets selected

    @Test func selectionFollowsItsFlowAcrossAHeadTrimAndAppend() {
        let harness = Harness()
        var rows = (0 ..< 50).map { flow($0) }
        harness.coordinator.update(rows: rows, capture: capture(rows), selection: nil)

        let selected = rows[20]
        harness.coordinator.update(rows: rows, capture: capture(rows), selection: selected.id)
        #expect(harness.table.selectedRow == 20)

        // The shape a capped window produces every batch: trim the head, append the tail.
        rows = Array(rows.dropFirst(5)) + (50 ..< 60).map { flow($0) }
        harness.coordinator.update(rows: rows, capture: capture(rows), selection: selected.id)
        #expect(
            harness.table.selectedRow == 15,
            "the selected row must still hold the selected flow after a 5-row head trim"
        )
        #expect(harness.table.selectedRow >= 0)
        #expect(rows[harness.table.selectedRow].id == selected.id)
    }

    @Test func aSelectionTheStoreMovedIsHonoured() {
        let harness = Harness()
        let rows = (0 ..< 50).map { flow($0) }
        harness.coordinator.update(rows: rows, capture: capture(rows), selection: rows[10].id)
        #expect(harness.table.selectedRow == 10)

        // Not adjacent, and no data change — only the scan can answer this one.
        harness.coordinator.update(rows: rows, capture: capture(rows), selection: rows[40].id)
        #expect(harness.table.selectedRow == 40)
    }

    @Test func clearingTheSelectionDeselects() {
        let harness = Harness()
        let rows = (0 ..< 20).map { flow($0) }
        harness.coordinator.update(rows: rows, capture: capture(rows), selection: rows[3].id)
        #expect(harness.table.selectedRow == 3)
        harness.coordinator.update(rows: rows, capture: capture(rows), selection: nil)
        #expect(harness.table.selectedRow == -1)
    }

    /// A selection whose flow left the window: nothing to select, and nothing selected.
    @Test func aSelectionTrimmedOutOfTheWindowDeselects() {
        let harness = Harness()
        let rows = (0 ..< 20).map { flow($0) }
        harness.coordinator.update(rows: rows, capture: capture(rows), selection: rows[1].id)
        #expect(harness.table.selectedRow == 1)

        let trimmed = Array(rows.dropFirst(5))
        harness.coordinator.update(rows: trimmed, capture: capture(trimmed), selection: rows[1].id)
        #expect(harness.table.selectedRow == -1, "a selection no longer in the list selects nothing")
    }

    // MARK: The property the fix is for

    /// Having a selection must not make a batch cost the window.
    ///
    /// Measured as the **overhead of a selection**, not as an absolute time and not as a
    /// ratio between two window sizes. Both of those measure the wrong thing: an update at
    /// 20 000 rows genuinely costs more than one at 1 000 (`NSTableView`'s own
    /// `removeRows`/`insertRows` bookkeeping is 14× across that range, and it is not what
    /// this change touches), so a cross-size ratio fails whatever the selection sync does.
    /// The same batch with and against without a selection isolates exactly the code path
    /// in question.
    ///
    /// Measured on an M-series Mac, 20 000 rows, a 20-row trim-and-append batch:
    ///
    /// | | median update |
    /// |---|---|
    /// | no selection | 1.06 ms |
    /// | selection, scanning (before) | **3.08 ms** — 2.79× |
    /// | selection, asking the table (after) | 1.11 ms — 1.04× |
    ///
    /// So the scan was ~2 ms of main thread per batch, ten times a second, to re-find a row
    /// that had not moved. The bound sits between the two: comfortably above the noise on a
    /// loaded runner, comfortably under the regression.
    @Test func aSelectionDoesNotMakeABatchCostTheWindow() {
        let withSelection = Self.medianUpdateMS(rowCount: 20_000, selected: true)
        let withoutSelection = Self.medianUpdateMS(rowCount: 20_000, selected: false)
        let overhead = withSelection / max(withoutSelection, 0.001)
        #expect(
            overhead < 1.5,
            """
            A batch cost \(withSelection) ms with a selection against \(withoutSelection) ms \
            without — \(overhead)× for the same edit. Having something selected is not \
            supposed to be visible in the update cost at all; this is the shape of \
            `applySelection` falling back to `rows.firstIndex` on every batch instead of \
            asking the table where its selection already is.
            """
        )
    }

    private static func medianUpdateMS(rowCount: Int, selected: Bool) -> Double {
        let harness = Harness()
        var rows = (0 ..< rowCount).map { n in
            Flow(
                id: UUID(),
                request: CapturedRequest(method: "GET", url: "https://api.test/\(n)", headers: []),
                startedAt: Date(timeIntervalSince1970: TimeInterval(n)),
                outcome: .completed(
                    CapturedResponse(statusCode: 200, headers: []),
                    at: Date(timeIntervalSince1970: TimeInterval(n) + 0.1)
                )
            )
        }
        func captured(_ rows: [Flow]) -> IdentifiedArrayOf<Flow> { IdentifiedArrayOf(uniqueElements: rows) }
        harness.coordinator.update(rows: rows, capture: captured(rows), selection: nil)
        let selection = selected ? rows[rowCount / 2].id : nil
        harness.coordinator.update(rows: rows, capture: captured(rows), selection: selection)

        var samples: [Double] = []
        var next = rowCount
        for _ in 0 ..< 30 {
            let batch = (next ..< next + 20).map { n in
                Flow(
                    id: UUID(),
                    request: CapturedRequest(method: "GET", url: "https://api.test/\(n)", headers: []),
                    startedAt: Date(timeIntervalSince1970: TimeInterval(n)),
                    outcome: .completed(
                        CapturedResponse(statusCode: 200, headers: []),
                        at: Date(timeIntervalSince1970: TimeInterval(n) + 0.1)
                    )
                )
            }
            next += 20
            rows = Array(rows.dropFirst(20)) + batch
            let capture = captured(rows)
            let started = DispatchTime.now().uptimeNanoseconds
            harness.coordinator.update(rows: rows, capture: capture, selection: selection)
            samples.append(Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000)
        }
        return samples.sorted()[samples.count / 2]
    }
}
