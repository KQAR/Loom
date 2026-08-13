import AppKit
import ComposableArchitecture
import Foundation
import LoomSharedModels
import SwiftUI
import Testing

@testable import AppFeature

/// The column behaviours that are decisions rather than AppKit doing its job: which columns
/// are hidden (and survive a relaunch), what "fit this column to its content" answers, and
/// where a window's spare width goes.
@MainActor
@Suite struct RequestTableColumnTests {
    private func defaults(_ name: String = UUID().uuidString) -> UserDefaults {
        UserDefaults(suiteName: name)!
    }

    // MARK: Hidden columns

    @Test func hiddenColumnsRoundTrip() {
        let store = defaults()
        RequestTable.Column.setHiddenColumns([.app, .proto], store)
        #expect(RequestTable.Column.hiddenColumns(store) == [.app, .proto])
    }

    @Test func nothingIsHiddenByDefault() {
        #expect(RequestTable.Column.hiddenColumns(defaults()).isEmpty)
    }

    /// A table with every column hidden is a blank rectangle, and the menu that would
    /// unhide one lives on a header that then has nothing to draw. Whatever is on disk —
    /// a hand-edited plist, a future column set that shrank — at least one column shows.
    @Test func hidingEveryColumnIsRefusedOnRead() {
        let store = defaults()
        RequestTable.Column.setHiddenColumns(Set(RequestTable.Column.allCases), store)
        #expect(RequestTable.Column.hiddenColumns(store).isEmpty)
    }

    @Test func unknownStoredColumnsAreIgnored() {
        let store = defaults()
        store.set(["host", "not-a-column"], forKey: RequestTable.Column.hiddenColumnsDefaultsKey)
        #expect(RequestTable.Column.hiddenColumns(store) == [.host])
    }

    /// Every column has to be nameable in the chooser, including the two whose header is
    /// a glyph with no title — an unnamed menu item is an empty row nobody can act on.
    @Test func everyColumnHasAMenuTitle() {
        for column in RequestTable.Column.allCases {
            #expect(!column.menuTitle.isEmpty)
        }
    }

    // MARK: Fit to content

    @Test func fittingWidthGrowsWithTheLongestValue() {
        let short = [Fixtures.flow(url: "https://a.co/x")]
        let long = [Fixtures.flow(url: "https://a.co/" + String(repeating: "segment/", count: 20))]
        let narrow = RequestTable.fittingWidth(for: .path, rows: short, capture: IdentifiedArray(uniqueElements: short))
        let wide = RequestTable.fittingWidth(for: .path, rows: long, capture: IdentifiedArray(uniqueElements: long))
        #expect(wide > narrow)
    }

    /// Fitting a column to its content must not make it narrower than the word naming it:
    /// `Protocol` is a longer string than every value that column ever holds.
    @Test func fittingWidthNeverClipsTheHeader() {
        let rows = [Fixtures.flow(url: "https://a.co/x")]
        let width = RequestTable.fittingWidth(for: .proto, rows: rows, capture: IdentifiedArray(uniqueElements: rows))
        let header = ("Protocol" as NSString)
            .size(withAttributes: [.font: NSFont.preferredFont(forTextStyle: .caption1)]).width
        #expect(width >= header)
    }

    /// The glyph columns have nothing to measure and a width they are pinned to anyway.
    @Test func glyphColumnsKeepTheirWidth() {
        let rows = [Fixtures.flow()]
        let capture = IdentifiedArray(uniqueElements: rows)
        #expect(RequestTable.fittingWidth(for: .status, rows: rows, capture: capture)
            == RequestTable.Column.status.idealWidth)
        #expect(RequestTable.fittingWidth(for: .app, rows: rows, capture: capture)
            == RequestTable.Column.app.idealWidth)
    }

    /// An empty list still has a header to fit, and must not answer zero — a column
    /// double-clicked before any traffic arrives would collapse to nothing.
    @Test func fittingWidthOnAnEmptyListStillFitsTheHeader() {
        let width = RequestTable.fittingWidth(for: .host, rows: [], capture: [])
        #expect(width > 0)
    }

    /// Bounded on purpose: this runs on a gesture, but the window holds thousands of rows
    /// and the widest column is the one with the longest strings. Only the newest rows —
    /// the ones being looked at — are measured.
    // MARK: Filling the width

    /// A table wired the way `makeNSView` wires one, driven without a window.
    @MainActor
    private final class WidthHarness {
        let table = NSTableView()
        let scrollView = NSScrollView()
        let coordinator: RequestTable.Coordinator

        init(hiding hidden: Set<RequestTable.Column> = []) {
            coordinator = RequestTable.Coordinator(
                selection: .constant(nil), followTail: .constant(true),
                onReplay: { _ in }, onCopyCurl: { _ in }, onAddRule: { _, _ in },
                onStopDecrypting: { _ in }
            )
            // Both matter to the arithmetic: `.inset` decides the edge insets and intercell
            // spacing the trailing edge is measured against, and the autoresizing style is
            // what hands the slack to this code instead of to the rightmost column.
            table.style = .inset
            table.columnAutoresizingStyle = .noColumnAutoresizing
            for spec in RequestTable.Column.allCases {
                let column = NSTableColumn(identifier: spec.identifier)
                column.minWidth = spec.minWidth
                column.width = spec.idealWidth
                column.maxWidth = spec.maxWidth
                column.isHidden = hidden.contains(spec)
                table.addTableColumn(column)
            }
            scrollView.documentView = table
            coordinator.attach(scrollView: scrollView, table: table)
        }

        func resize(to width: CGFloat) {
            scrollView.frame = NSRect(x: 0, y: 0, width: width, height: 600)
            scrollView.layoutSubtreeIfNeeded()
            coordinator.layoutColumns()
        }

        func width(_ spec: RequestTable.Column) -> CGFloat {
            table.tableColumns.first { $0.identifier == spec.identifier }!.width
        }

        /// What the operator sees: the distance from the last column's trailing edge to the
        /// viewport's. Anything but zero is the dead strip this layout exists to remove.
        ///
        /// Read off `rect(ofColumn:)`, never `table.frame.width` — a scroll view stretches
        /// its document view to the viewport, so the frame reports the width the table was
        /// *given*, and a test written against it passes while the strip is still there.
        var trailingGap: CGFloat {
            let last = table.tableColumns.lastIndex { !$0.isHidden }!
            return scrollView.contentView.bounds.width - table.rect(ofColumn: last).maxX
        }
    }

    /// The complaint this replaced: widening the window grew Time to its cap and left dead
    /// space, because AppKit's default hands the slack to the *rightmost* column.
    @Test func wideningTheWindowLeavesNothingAtTheRight() {
        let harness = WidthHarness()
        for width in [700.0, 1200.0, 1800.0, 2600.0] {
            harness.resize(to: width)
            #expect(abs(harness.trailingGap) <= 0.5, "gap of \(harness.trailingGap) at \(width)")
        }
    }

    /// And it goes to the two columns that hold unbounded text, not to Time.
    @Test func theSpareWidthGoesToHostAndPath() {
        let harness = WidthHarness()
        harness.resize(to: 900)
        let narrow = (host: harness.width(.host), path: harness.width(.path), time: harness.width(.time))
        harness.resize(to: 1900)
        #expect(harness.width(.host) > narrow.host)
        #expect(harness.width(.path) > narrow.path)
        #expect(harness.width(.time) == narrow.time)
        #expect(harness.width(.method) == RequestTable.Column.method.idealWidth)
    }

    /// Host has a cap because a host name has a length; past it, Path takes the rest alone.
    @Test func hostStopsAtItsCapAndPathKeepsGoing() {
        let harness = WidthHarness()
        harness.resize(to: 3000)
        #expect(harness.width(.host) == RequestTable.Column.host.maxWidth)
        #expect(abs(harness.trailingGap) <= 0.5)
    }

    /// A width the operator set by hand is theirs — the spare space goes around it.
    @Test func aHandSizedHostIsNotResized() {
        let harness = WidthHarness()
        harness.resize(to: 900)
        let host = harness.table.tableColumns.first { $0.identifier == RequestTable.Column.host.identifier }!
        host.width = 140
        harness.resize(to: 1900)
        #expect(harness.width(.host) == 140)
        #expect(abs(harness.trailingGap) <= 0.5)
    }

    /// With Path hidden, Host becomes the sink — and stops honouring the cap that would
    /// otherwise reopen the gap on the right.
    @Test func hostAbsorbsWhenPathIsHidden() {
        let harness = WidthHarness(hiding: [.path])
        harness.resize(to: 1600)
        #expect(harness.width(.host) > RequestTable.Column.host.maxWidth)
        #expect(abs(harness.trailingGap) <= 0.5)
    }

    /// A window too narrow for the columns scrolls horizontally rather than crushing Path
    /// below the width its own content needs.
    @Test func tooNarrowScrollsInsteadOfCrushingPath() {
        let harness = WidthHarness()
        harness.resize(to: 320)
        #expect(harness.width(.path) == RequestTable.Column.path.minWidth)
        #expect(harness.trailingGap < 0)
    }

    /// The sink is a property of what is visible, not a fixed column.
    @Test func theSinkFollowsWhatIsVisible() {
        #expect(RequestTable.slackSink(among: RequestTable.Column.allCases) == .path)
        #expect(RequestTable.slackSink(among: [.status, .host, .time]) == .host)
        #expect(RequestTable.slackSink(among: [.status, .time]) == .time)
        #expect(RequestTable.slackSink(among: []) == nil)
    }

    @Test func fittingWidthReadsOnlyTheNewestRows() {
        let old = Fixtures.flow(url: "https://a.co/" + String(repeating: "x", count: 400))
        let recent = (0 ..< RequestTable.sizeToFitRowBudget).map { _ in Fixtures.flow(url: "https://a.co/s") }
        let rows = [old] + recent
        let capture = IdentifiedArray(uniqueElements: rows)
        let withOld = RequestTable.fittingWidth(for: .path, rows: rows, capture: capture)
        let withoutOld = RequestTable.fittingWidth(for: .path, rows: recent, capture: capture)
        #expect(withOld == withoutOld)
    }
}
