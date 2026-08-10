import AppKit
import ComposableArchitecture
import Foundation
import LoomSharedModels
import Testing

@testable import AppFeature

/// The two column behaviours that are decisions rather than AppKit doing its job: which
/// columns are hidden (and survive a relaunch), and what "fit this column to its content"
/// answers.
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
