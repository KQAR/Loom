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
                onDecryptHost: { _ in }, onExcludeHost: { _ in },
                sslScope: SSLScope(enabled: true, include: ["*"])
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
    ///
    /// This one asserts on `abs`, so it can only run where the columns *fit* — below
    /// that the gap is legitimately negative and the assertion would be measuring "this
    /// window is narrow". The floor is the column set's own minimum: 550pt of widths
    /// plus ~17.5pt per column of `.inset` padding and intercell spacing, ~708pt for the
    /// nine columns, which is why it starts at 800 rather than the 700 it used to. The
    /// window's own default gives the table 740 (1040 less a 300pt sidebar), so the
    /// narrow end is a deliberately-shrunk window and belongs to the test below.
    @Test func wideningTheWindowLeavesNothingAtTheRight() {
        let harness = WidthHarness()
        for width in [800.0, 1200.0, 1800.0, 2600.0] {
            harness.resize(to: width)
            #expect(abs(harness.trailingGap) <= 0.5, "gap of \(harness.trailingGap) at \(width)")
        }
    }

    /// **Dead space and overflow are different failures**, and only one of them is this
    /// layout's to prevent. A *positive* gap is the dead strip above — the columns fit
    /// and nobody claimed the remainder — and it must never appear at any width. A
    /// negative one means the columns want more than the viewport has, which is what
    /// horizontal scrolling is for; asserting `abs(gap)` treated the two as one bug and
    /// so turned "this window is narrow" into a test failure.
    ///
    /// The floor is real, though: every column costs ~17.5pt of `.inset` padding and
    /// intercell spacing on top of its width, so a column set that overflows a viewport
    /// someone can actually produce is a column set that is too wide. 640pt is below
    /// anything the window offers (`defaultSize` is 1040 with a 300pt sidebar) and is
    /// where scrolling is allowed to start.
    @Test func noWidthLeavesDeadSpaceAtTheRight() {
        let harness = WidthHarness()
        for width in stride(from: 640.0, through: 3200.0, by: 40.0) {
            harness.resize(to: width)
            #expect(harness.trailingGap <= 0.5, "dead space of \(harness.trailingGap) at \(width)")
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

    // MARK: The Decrypted column

    /// The reading of the glyph is the part that is easy to get backwards: the lock is
    /// the **traffic's** state, so a closed lock means these bytes stayed encrypted to
    /// Loom and there is no body on the row. Putting the reassuring glyph on the row
    /// whose contents are missing is the failure mode.
    @Test func theLockColumnSaysWhetherLoomReadTheExchange() {
        let decrypted = FlowEncryption(Fixtures.flow(url: "https://api.test/v1"))
        let tunnelled = FlowEncryption(Fixtures.flow(method: "CONNECT", url: "https://api.test:443"))
        let plaintext = FlowEncryption(Fixtures.flow(url: "http://api.test/v1"))

        #expect(decrypted.glyph == "lock.open.fill")
        #expect(tunnelled.glyph == "lock.fill")
        #expect(plaintext.glyph == "lock.slash")

        #expect(tunnelled.help.contains("Not decrypted"))
        #expect(decrypted.help.contains("Loom read"))
        #expect(plaintext.help.contains("nothing to decrypt"))
    }

    /// **Failed and not-attempted are different answers**, and drawing them alike is
    /// the more misleading direction of the two: a deliberate pass-through is the
    /// configuration working, while a refused handshake is a request that never
    /// happened. The discriminator is the flow's own error — `TunnelFlow.record`
    /// completes a relayed tunnel with a 200, `recordFailure` fails it.
    @Test func aFailedDecryptionIsItsOwnStateNotAPassThrough() {
        let relayed = FlowEncryption(Fixtures.flow(method: "CONNECT", url: "https://carved.test:443"))
        let failed = FlowEncryption(
            Fixtures.flow(method: "CONNECT", url: "https://pinned.test:443",
                          error: "Client refused Loom's certificate — sslError")
        )
        #expect(relayed.glyph != failed.glyph)
        #expect(failed.glyph == "lock.trianglebadge.exclamationmark")
        #expect(failed.help.contains("Decryption failed"))
        #expect(failed.help.contains("never reached the origin"),
                "the row has to say the request did not happen, not merely that it was unread")
    }

    /// The column carries its own header word. Four states of one symbol are not
    /// guessable from the symbol, and the width follows the header rather than the
    /// glyph — which is the only thing in this column that has a size.
    @Test func theLockColumnIsNamedInItsHeader() {
        #expect(RequestTable.Column.lock.title == "Decrypted")
        #expect(RequestTable.Column.lock.menuTitle == "Decrypted")
        #expect(RequestTable.Column.lock.minWidth >= 60, "narrower than the word it shows would truncate the header")
    }

    /// `wss://` is a TLS handshake Loom terminated like any other, and a lowercase check
    /// must not depend on the client's spelling of the scheme.
    @Test func theLockColumnCountsWebSocketsAndIgnoresSchemeCasing() {
        #expect(FlowEncryption(Fixtures.flow(url: "wss://api.test/socket")).glyph == "lock.open.fill")
        #expect(FlowEncryption(Fixtures.flow(url: "ws://api.test/socket")).glyph == "lock.slash")
        #expect(FlowEncryption(Fixtures.flow(url: "HTTPS://api.test/v1")).glyph == "lock.open.fill")
        #expect(FlowEncryption(Fixtures.flow(method: "connect", url: "https://a.test:443")).glyph == "lock.fill")
    }

    // MARK: The parent-wildcard menu item

    /// One label up, never "the registrable domain" — that needs a public-suffix list,
    /// and guessing it with "keep the last two labels" answers `*.co.uk` for
    /// `shop.example.co.uk`.
    @Test func theParentWildcardWidensByExactlyOneLevel() {
        #expect(RequestTable.Coordinator.parentWildcard(for: "test-mex-ec-api.fintopia.tech") == "*.fintopia.tech")
        #expect(RequestTable.Coordinator.parentWildcard(for: "api.test.example.com") == "*.test.example.com")
        #expect(RequestTable.Coordinator.parentWildcard(for: "shop.example.co.uk") == "*.example.co.uk")
    }

    /// The two hosts with no safe answer. `example.com` would widen to `*.com`, and an
    /// IPv4 address has the shape of a domain and none of the meaning.
    @Test func theParentWildcardRefusesWhereItWouldBeWrong() {
        #expect(RequestTable.Coordinator.parentWildcard(for: "example.com") == nil)
        #expect(RequestTable.Coordinator.parentWildcard(for: "localhost") == nil)
        #expect(RequestTable.Coordinator.parentWildcard(for: "10.0.12.93") == nil)
        #expect(RequestTable.Coordinator.parentWildcard(for: "127.0.0.1") == nil)
        // Malformed rather than dangerous, but a glob with an empty label matches
        // nothing and would sit in the list looking like it works.
        #expect(RequestTable.Coordinator.parentWildcard(for: "a..b.com") == nil)
    }
}
