import AppKit
import SwiftUI

/// The request table's one AppKit reach-in. Two jobs, deliberately in one bridge:
///
/// 1. **Tail-follow** — pin to the newest row as the list grows, the way a log viewer
///    does, and step out of the way the moment the user scrolls. SwiftUI's `Table` is
///    `NSTableView`-backed and `ScrollViewReader` doesn't reliably drive it.
/// 2. **Row background for a failed exchange** — `Table` has no row-background API on
///    macOS at all, and `NSTableRowView.backgroundColor` is exactly that API one layer
///    down. It was first done in pure SwiftUI, as a fill on every cell with a bleed to
///    cover the inter-column gutter, and it is worth saying why that is gone: a
///    per-cell fill is eight rectangles pretending to be one, so it showed seams where
///    the bleed fell short and doubled-opacity bands where two bleeds overlapped, and
///    every new column had to remember to join in. A row is one thing; it gets one
///    fill.
///
/// One bridge rather than two because both need the same `NSTableView`, found by the
/// same recursive walk, and invalidated by the same scroll notifications — a second
/// representable would duplicate the search, the observers and the teardown.
struct RequestTableBridge: NSViewRepresentable {
    /// Drives updates: a change re-runs `updateNSView`, where we scroll if following.
    let rowCount: Int
    /// Row indices (into the table's current order) whose exchange failed. Recomputed
    /// by the caller per render, which is one O(n) pass over an array it already has.
    let failedRows: IndexSet
    @Binding var follow: Bool

    func makeCoordinator() -> Coordinator { Coordinator(follow: $follow) }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async { context.coordinator.attachIfNeeded(from: view) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            context.coordinator.attachIfNeeded(from: nsView)
            // Only when the row count actually moved. `updateNSView` runs on every
            // render of the table, and the table re-renders for any state change it
            // observes — not just a new flow — so an unconditional scroll spent main
            // thread on renders that hadn't added a row.
            if follow { context.coordinator.scrollToBottomIfRowCountChanged(rowCount) }
            // Unconditional, unlike the scroll: the set can change without the count
            // changing (a pending row completes with a 500, a filter switches), and it
            // is a walk over the *visible* rows only, so it is bounded by the viewport.
            context.coordinator.setFailedRows(failedRows)
        }
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.detach()
    }

    final class Coordinator {
        @Binding var follow: Bool
        private weak var scrollView: NSScrollView?
        private var failedRows = IndexSet()

        init(follow: Binding<Bool>) { _follow = follow }

        func attachIfNeeded(from view: NSView) {
            guard scrollView == nil, let root = view.window?.contentView,
                  let sv = Self.findTableScrollView(in: root)
            else { return }
            scrollView = sv
            let nc = NotificationCenter.default
            nc.addObserver(self, selector: #selector(userWillScroll),
                           name: NSScrollView.willStartLiveScrollNotification, object: sv)
            // Track during the gesture AND its momentum so re-follow triggers the
            // instant the bottom is reached, not just when the finger lifts.
            nc.addObserver(self, selector: #selector(userScrolling),
                           name: NSScrollView.didLiveScrollNotification, object: sv)
            nc.addObserver(self, selector: #selector(userScrolling),
                           name: NSScrollView.didEndLiveScrollNotification, object: sv)
            // Row views are recycled, so a row scrolling into view arrives wearing
            // whichever fill its predecessor had. The clip view's bounds change on
            // *every* scroll, user-driven or programmatic — unlike the live-scroll
            // notifications above, which is why tail-follow can't stand in for it.
            sv.contentView.postsBoundsChangedNotifications = true
            nc.addObserver(self, selector: #selector(viewportChanged),
                           name: NSView.boundsDidChangeNotification, object: sv.contentView)
        }

        func detach() { NotificationCenter.default.removeObserver(self) }

        @objc private func userWillScroll() {
            if follow { follow = false } // user took control
        }

        @objc private func userScrolling() {
            // Follow iff they're at the bottom; only write when it actually changes.
            let atBottom = isAtBottom()
            if follow != atBottom { follow = atBottom }
        }

        @objc private func viewportChanged() { applyRowFills() }

        // MARK: Failed-row fill

        func setFailedRows(_ rows: IndexSet) {
            // The fill has to be re-applied even when the set is unchanged: a reload
            // hands back fresh row views with no fill, and this runs right after the
            // render that caused it.
            failedRows = rows
            applyRowFills()
        }

        /// Paints the *whole* row, `NSTableRowView` being the only thing in this stack
        /// that owns a row-sized rectangle.
        ///
        /// Both branches are load-bearing: a recycled row view keeps its predecessor's
        /// `backgroundColor`, so the `else` is what stops the fill from smearing onto
        /// healthy rows during a scroll. `enumerateAvailableRowViews` visits only what
        /// is realized, so cost is the viewport, not the capture.
        private func applyRowFills() {
            guard let table = scrollView?.documentView as? NSTableView else { return }
            let fill = LoomTheme.rowFillError
            table.enumerateAvailableRowViews { [failedRows] rowView, row in
                rowView.backgroundColor = failedRows.contains(row) ? fill : .clear
            }
        }

        /// Last row count this coordinator scrolled for. `nil` until the first scroll,
        /// so the initial attach still pins to the newest row.
        private var lastScrolledRowCount: Int?

        /// Tail-follow, but only when the list actually grew or shrank. Re-following
        /// after the user scrolls back to the bottom still works: `userScrolling`
        /// flips `follow`, and the next row arrival scrolls.
        func scrollToBottomIfRowCountChanged(_ rowCount: Int) {
            guard lastScrolledRowCount != rowCount else { return }
            lastScrolledRowCount = rowCount
            scrollToBottom()
        }

        func scrollToBottom() {
            guard let table = scrollView?.documentView as? NSTableView, table.numberOfRows > 0 else { return }
            table.scrollRowToVisible(table.numberOfRows - 1)
        }

        private func isAtBottom() -> Bool {
            guard let table = scrollView?.documentView as? NSTableView, table.numberOfRows > 0 else { return true }
            let visible = table.rows(in: table.visibleRect)
            return NSMaxRange(visible) >= table.numberOfRows
        }

        /// The request table's scroll view = an NSScrollView whose documentView is a
        /// multi-column NSTableView (the sidebar's list has a single column).
        private static func findTableScrollView(in view: NSView) -> NSScrollView? {
            if let sv = view as? NSScrollView,
               let table = sv.documentView as? NSTableView, table.numberOfColumns > 1 {
                return sv
            }
            for sub in view.subviews {
                if let found = findTableScrollView(in: sub) { return found }
            }
            return nil
        }
    }
}
