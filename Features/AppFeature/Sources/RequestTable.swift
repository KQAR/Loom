import AppKit
import ComposableArchitecture
import LoomSharedModels
import SwiftUI

/// The request table, as an `NSTableView` this view owns rather than one SwiftUI
/// builds and this view reaches into.
///
/// ## Why not SwiftUI's `Table`
///
/// Row *bodies* are lazy in `Table` — measured, 32 evaluated whether the data is 2 000
/// rows or 100 000. The collection is not: `Table` walks it end to end and reads every
/// element's `id`, and on a data change it does so about five times (measured: 100 006
/// subscripts for 20 001 rows, 70–120 ms per update). With capture batches landing
/// every 100 ms that is the main thread, and it makes a paged data source impossible by
/// construction — every walk would become 20 000 SQLite reads.
///
/// `NSTableView` asks `tableView(_:viewFor:row:)` only for rows it is about to draw.
/// That is the whole reason for this file: the cost of an update is the viewport's, not
/// the capture's, so the window can hold 20 000 rows and still apply a batch in ~1.7 ms.
/// (It said "the window can hold a page instead of the capture" — it holds the capture;
/// `FlowStore.page` exists but nothing pages it. What `Table` made impossible was a
/// paged data source, which is a reason this file *could* be extended, not a description
/// of what it does.)
///
/// ## What did not change
///
/// The cell *contents* are still the SwiftUI views they were — `StatusDot`,
/// `AppIconView`, `FaviconView`, the same fonts and tints — hosted per cell and
/// recycled with the row. Rewriting them in AppKit would have been a second port with
/// its own bugs, and it would have split the styling that DESIGN.md governs across two
/// idioms. What moved down a layer is *who owns the rows*, not what a row looks like.
///
/// This replaces `RequestTableBridge`, which existed to reach the same `NSTableView`
/// through a recursive view-tree search for two jobs SwiftUI could not do (tail-follow
/// and a row-sized fill). Both are native here.
struct RequestTable: NSViewRepresentable {
    /// Version-stamped (`Versioned`): AttributeGraph compares a representable's
    /// stored properties to decide whether the view changed, and comparing 20 000
    /// `Flow`s elementwise to learn what the stamp says in O(1) was a measured
    /// quarter of the main thread. Unwrapped into the coordinator below, which is
    /// past the comparison and works in plain values.
    let rows: Versioned<[Flow]>
    /// The whole capture, for the `#` column's 1-based position.
    ///
    /// The array itself rather than a precomputed `id → ordinal` dictionary: that
    /// dictionary was rebuilt on every capture batch, which is an allocation and a hash
    /// per retained flow ten times a second — measured at 20 000 rows, a meaningful
    /// share of the whole update. `IdentifiedArray.index(id:)` is O(1), so looking it up
    /// per *visible* cell costs the viewport instead of the capture. Passing the array
    /// is free (COW), and it is a value here, so no cell observes the store.
    let capture: Versioned<IdentifiedArrayOf<Flow>>
    @Binding var selection: Flow.ID?
    @Binding var followTail: Bool
    /// Row actions, as closures rather than a store reference: this view is about
    /// drawing rows, and handing it the store would let a cell reach anything.
    let onReplay: (Flow.ID) -> Void
    let onCopyCurl: (Flow.ID) -> Void
    let onAddRule: (Flow.ID, RuleTemplate) -> Void
    /// Both directions of the scope, by host name rather than by flow id: the scope is
    /// keyed on the host and the row is only how the operator picked one. Decrypt adds
    /// to the whitelist (a relayed row), Exclude carves out of it (a decrypted row, or
    /// one whose decryption failed).
    let onDecryptHost: (String) -> Void
    let onExcludeHost: (String) -> Void
    /// The live scope, so the menu can ask whether excluding would change anything
    /// rather than guessing from the URL. A value, not the store: this view draws rows.
    let sslScope: SSLScope

    /// Fixed, not automatic: `usesAutomaticRowHeights` measures every row it draws, and
    /// every row here is one line of text by construction.
    static let rowHeight: CGFloat = 24

    func makeCoordinator() -> Coordinator {
        Coordinator(selection: $selection, followTail: $followTail,
                    onReplay: onReplay, onCopyCurl: onCopyCurl, onAddRule: onAddRule,
                    onDecryptHost: onDecryptHost, onExcludeHost: onExcludeHost,
                    sslScope: sslScope)
    }

    func makeNSView(context: Context) -> RequestScrollView {
        let table = NSTableView()
        table.style = .inset
        table.rowHeight = Self.rowHeight
        table.usesAlternatingRowBackgroundColors = true
        table.allowsMultipleSelection = false
        table.allowsColumnReordering = false
        table.allowsColumnSelection = false
        table.headerView = NSTableHeaderView()
        table.dataSource = context.coordinator
        table.delegate = context.coordinator
        table.target = context.coordinator
        table.menu = context.coordinator.makeRowMenu()
        table.headerView?.menu = context.coordinator.makeHeaderMenu()

        // The columns are laid out by `Coordinator.layoutColumns`, not by AppKit. The default
        // (`.lastColumnOnlyAutoresizingStyle`) hands every extra point to the *rightmost*
        // column, which here is Time — capped at 100 — so widening the window grew Time to its
        // cap and then left dead space to the right of it, while Path, the one column never
        // wide enough, stayed exactly as narrow as it started.
        table.columnAutoresizingStyle = .noColumnAutoresizing

        let hidden = Column.hiddenColumns()
        for spec in Column.allCases {
            let column = NSTableColumn(identifier: spec.identifier)
            column.title = spec.title
            column.minWidth = spec.minWidth
            column.width = spec.idealWidth
            column.maxWidth = spec.maxWidth
            column.resizingMask = spec.maxWidth > spec.minWidth ? .userResizingMask : []
            column.isHidden = hidden.contains(spec)
            table.addTableColumn(column)
        }

        // A scroll view that says when it laid out, which is the only moment the initial
        // tail scroll can work: the first batch of rows arrives before this view has a
        // size, so the bottom is 0 and scrolling to it does nothing.
        let scrollView = RequestScrollView()
        scrollView.documentView = table
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.onLayout = { [weak coordinator = context.coordinator] in
            coordinator?.scrollViewDidLayout()
        }
        context.coordinator.attach(scrollView: scrollView, table: table)
        return scrollView
    }

    func updateNSView(_ scrollView: RequestScrollView, context: Context) {
        // The scope's other writer is an agent, so it is re-read here rather than
        // captured once at `makeCoordinator` — a menu built from a stale scope offers
        // to exclude a host that was excluded a minute ago.
        context.coordinator.sslScope = sslScope
        context.coordinator.update(rows: rows, capture: capture, selection: selection)
    }

    static func dismantleNSView(_ scrollView: RequestScrollView, coordinator: Coordinator) {
        coordinator.detach()
    }

    // MARK: Columns

    /// The column set, as data rather than eight near-identical construction sites.
    /// Widths carried over verbatim from the SwiftUI `Table` this replaces, including
    /// the reasoning attached to two of them.
    enum Column: String, CaseIterable {
        case status, ordinal, app, lock, proto, method, host, path, time

        var identifier: NSUserInterfaceItemIdentifier { .init(rawValue) }

        var title: String {
            switch self {
            case .status: ""
            case .ordinal: "#"
            case .app: "App"
            case .lock: "SSL"
            case .proto: "Protocol"
            case .method: "Method"
            case .host: "Host"
            case .path: "Path"
            case .time: "Time"
            }
        }

        /// Horizontal inset of the SwiftUI body inside `HostingCell`, each side.
        ///
        /// Shared 4pt everywhere except `#`: five caption digits measure 32pt and
        /// the column's ideal width is 38, so 4pt a side clips the cap. The other
        /// columns are wide enough that the inset keeps a glyph off the divider;
        /// this one spends those points on the digits.
        var cellInset: CGFloat {
            switch self {
            case .ordinal: 1
            default: 4
            }
        }

        var minWidth: CGFloat {
            switch self {
            case .status: 28
            case .ordinal: 30
            case .app, .lock: 36
            // Sized to the widest token this column can hold — `HTTPS`, 5 mono glyphs —
            // not to the header word, which is the only thing here that wants more room.
            case .proto: 46
            case .method: 52
            case .host: 140
            // Lower than it reads: Path is the slack sink, so it is back above 300pt the
            // moment the window has room, and this floor only bites in a viewport
            // narrower than the columns want. It came down from 160 when the SSL column
            // was added at 72pt (headed "Decrypted") — every column costs ~17.5pt of
            // `.inset` padding and intercell spacing *beyond* its width, so a 9-column
            // table at a 700pt viewport (a 1000pt window, or a 700pt one with the
            // sidebar collapsed) was 40pt over even with Host and Path both on their
            // floors. The column is 36pt now and Host's floor took 30 of the 36 back,
            // so the nine floors total ~701pt at that viewport: still over, which is
            // what horizontal scrolling is for, and raising this floor again would
            // spend the one column that is never wide enough.
            case .path: 120
            case .time: 56
            }
        }

        var idealWidth: CGFloat {
            switch self {
            case .status: 28
            case .ordinal: 38
            case .app, .lock: 36
            case .proto: 52
            case .method: 62
            case .host: 220
            case .path: 320
            case .time: 70
            }
        }

        var maxWidth: CGFloat {
            switch self {
            // Sized for five digits, not seven: the caps are in `FlowLimits` and the
            // largest is five digits, so this is headroom already — and every
            // point it took came off Path, the one column never wide enough.
            case .status: 28
            case .ordinal: 56
            case .app, .lock: 36
            case .proto: 64
            case .method: 90
            case .host: 340
            case .path: 10_000
            case .time: 100
            }
        }

        /// The name shown in the header's column menu. Status draws a glyph and has no
        /// header text, so the menu is the one place it can be named; SSL used to be
        /// the second such column (blank, then "Decrypted") and now carries its own
        /// header, because four states of one symbol are not guessable from it.
        var menuTitle: String {
            switch self {
            case .status: "Status"
            case .ordinal: "Number"
            default: title
            }
        }

        /// Which columns are hidden, remembered across launches.
        ///
        /// A hidden column is invisible by definition, so an operator who hid one and
        /// relaunched would have no way to tell why the list looks wrong — the state has
        /// to survive with the window that shows it, and the header menu is the only place
        /// it can be read back.
        static let hiddenColumnsDefaultsKey = "com.loom.table.hiddenColumns"

        static func hiddenColumns(_ defaults: UserDefaults = .standard) -> Set<Column> {
            let stored = defaults.stringArray(forKey: hiddenColumnsDefaultsKey) ?? []
            let hidden = Set(stored.compactMap(Column.init(rawValue:)))
            // A table with no columns is a blank rectangle with no way back — the menu
            // that would unhide one is on a header that has nothing left to draw. Whatever
            // is on disk, at least one column is shown.
            return hidden.count >= allCases.count ? [] : hidden
        }

        static func setHiddenColumns(_ hidden: Set<Column>, _ defaults: UserDefaults = .standard) {
            defaults.set(hidden.map(\.rawValue).sorted(), forKey: hiddenColumnsDefaultsKey)
        }
    }

    /// The width this column needs to show its widest content, for the double-click on a
    /// divider that `NSTableView` routes to `tableView(_:sizeToFitWidthOfColumn:)`.
    ///
    /// Text is measured against the same font the cell draws in — `.callout`, monospaced
    /// for every column that uses one — rather than SwiftUI's rendered result, which is
    /// not reachable from here. The difference is sub-point at these sizes; the padding
    /// added below is what actually decides whether the last glyph clips.
    static func fittingWidth(for column: Column, rows: [Flow], capture: IdentifiedArrayOf<Flow>) -> CGFloat {
        // Glyph columns have nothing to measure and a fixed width to begin with.
        guard column != .status, column != .app else { return column.idealWidth }

        let font = NSFont.monospacedSystemFont(
            ofSize: NSFont.preferredFont(forTextStyle: .callout).pointSize, weight: .regular
        )
        let attributes: [NSAttributedString.Key: Any] = [.font: font]
        var widest: CGFloat = 0
        // Bounded: this is a one-off gesture, but the window holds thousands of rows and
        // measuring every string in the widest column is not free. The newest rows are
        // the ones the operator is looking at.
        for flow in rows.suffix(sizeToFitRowBudget) {
            let text = switch column {
            case .ordinal: ordinalLabel((capture.index(id: flow.id) ?? 0) + 1)
            case .proto: MainView.protocolLabel(flow)
            case .method: flow.request.method
            case .host: MainView.hostReading(flow.request.url).label
            case .path: MainView.path(flow.request.url)
            case .time: flow.durationMS.map { "\($0)ms" } ?? "—"
            case .status, .app, .lock: ""
            }
            widest = max(widest, (text as NSString).size(withAttributes: attributes).width)
        }
        // The header's own title has to fit too, or fitting a column to its content can
        // make it narrower than the word naming it.
        let header = (column.title as NSString)
            .size(withAttributes: [.font: NSFont.preferredFont(forTextStyle: .caption1)]).width
        // Cell inset (per `Column.cellInset`) plus the favicon and its gap for the
        // one column that draws one, plus a point of slack so the last glyph never sits on
        // the boundary.
        let decoration: CGFloat = column == .host ? 16 + 6 : 0
        return max(widest, header) + decoration + column.cellInset * 2 + 1
    }

    /// Digits for the `#` column, with no locale grouping separator.
    ///
    /// `Text("\(n)")` interpolates through `LocalizedStringKey`, which inserts
    /// commas (or the locale's equivalent) past 999. The column is sized for five
    /// raw digits — `FlowLimits.windowRows` is 99 999 — so a separator would clip
    /// the cap, and a sequence number is not a quantity.
    static func ordinalLabel(_ ordinal: Int) -> String {
        String(ordinal)
    }

    /// How many of the newest rows a fit-to-content measurement reads.
    static let sizeToFitRowBudget = 2000

    // MARK: Filling the width

    /// The column that swallows whatever width the others don't want, so the rightmost column
    /// is always flush with the table's trailing edge.
    ///
    /// Path first — it is the only column whose content is unbounded, and its `maxWidth` says
    /// so. Host is the fallback for a table with Path hidden, and *as the sink it ignores its
    /// own `maxWidth`*: a cap on the sink is a gap on the right, which is the thing being
    /// fixed. `visible` is in the table's own column order, so the last-resort case picks the
    /// rightmost one.
    static func slackSink(among visible: [Column]) -> Column? {
        if visible.contains(.path) { return .path }
        if visible.contains(.host) { return .host }
        return visible.last
    }

    /// What Host takes out of the spare width when it is not the sink.
    ///
    /// The two absorb in the ratio of their ideal widths (220 : 320), so a wider window reads
    /// as the same table with more room rather than as a different layout — and Host stops at
    /// its `maxWidth`, because a host name has a length and Path does not.
    static func hostWidth(slack: CGFloat) -> CGFloat {
        let share = slack * (Column.host.idealWidth / (Column.host.idealWidth + Column.path.idealWidth))
        return min(max(share, Column.host.minWidth), Column.host.maxWidth)
    }

    // MARK: Coordinator

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
        @Binding private var selection: Flow.ID?
        @Binding private var followTail: Bool
        private let onReplay: (Flow.ID) -> Void
        private let onCopyCurl: (Flow.ID) -> Void
        private let onAddRule: (Flow.ID, RuleTemplate) -> Void
        private let onDecryptHost: (String) -> Void
        private let onExcludeHost: (String) -> Void
        /// Refreshed from `updateNSView`, not captured once — see the note there.
        var sslScope: SSLScope

        private weak var table: NSTableView?
        private weak var scrollView: NSScrollView?
        private var rows: [Flow] = []
        private var capture: IdentifiedArrayOf<Flow> = []
        /// The boxes the two above were unwrapped from, so an update that changed
        /// nothing can be recognised in two pointer compares — see `update`.
        private var rowsSource = Versioned<[Flow]>()
        private var captureSource = Versioned<IdentifiedArrayOf<Flow>>()
        /// Guards the selection write-back: `selectRowIndexes` fires the delegate, and
        /// echoing that back into the binding turns a programmatic sync into a user
        /// selection.
        private var applyingSelection = false

        init(
            selection: Binding<Flow.ID?>,
            followTail: Binding<Bool>,
            onReplay: @escaping (Flow.ID) -> Void,
            onCopyCurl: @escaping (Flow.ID) -> Void,
            onAddRule: @escaping (Flow.ID, RuleTemplate) -> Void,
            onDecryptHost: @escaping (String) -> Void,
            onExcludeHost: @escaping (String) -> Void,
            sslScope: SSLScope
        ) {
            _selection = selection
            _followTail = followTail
            self.onReplay = onReplay
            self.onCopyCurl = onCopyCurl
            self.onAddRule = onAddRule
            self.onDecryptHost = onDecryptHost
            self.onExcludeHost = onExcludeHost
            self.sslScope = sslScope
        }

        func attach(scrollView: NSScrollView, table: NSTableView) {
            self.scrollView = scrollView
            self.table = table
            let nc = NotificationCenter.default
            nc.addObserver(self, selector: #selector(userWillScroll),
                           name: NSScrollView.willStartLiveScrollNotification, object: scrollView)
            nc.addObserver(self, selector: #selector(userScrolling),
                           name: NSScrollView.didLiveScrollNotification, object: scrollView)
            nc.addObserver(self, selector: #selector(userDidEndScroll),
                           name: NSScrollView.didEndLiveScrollNotification, object: scrollView)
            // Every viewport move, whoever caused it — a gesture, its momentum, a scroller
            // drag, a keyboard scroll, **and this table's own edits**. It keeps `followTail`
            // reporting the truth to the rest of the window and decides nothing, which is
            // what `viewportDidMove` is separate from `userScrolling` for.
            let clipView = scrollView.contentView
            clipView.postsBoundsChangedNotifications = true
            nc.addObserver(self, selector: #selector(viewportDidMove),
                           name: NSView.boundsDidChangeNotification, object: clipView)
            // Object is nil rather than the window: this view has no window yet at attach
            // time, and it can move between windows afterwards. The handler filters.
            nc.addObserver(self, selector: #selector(windowOcclusionChanged),
                           name: NSWindow.didChangeOcclusionStateNotification, object: nil)
            nc.addObserver(self, selector: #selector(columnDidResize),
                           name: NSTableView.columnDidResizeNotification, object: table)
        }

        func detach() {
            stopGliding()
            NotificationCenter.default.removeObserver(self)
        }

        // MARK: Data

        func update(
            rows newRows: Versioned<[Flow]>,
            capture newCapture: Versioned<IdentifiedArrayOf<Flow>>,
            selection newSelection: Flow.ID?
        ) {
            // AttributeGraph used to answer "did anything move" before calling this, by
            // comparing 20 000 `Flow`s elementwise. It no longer can (that is the point
            // of `Versioned`), so the question is asked here instead and costs two
            // pointer compares: the contents object is replaced only when the reducer
            // assigned a new window.
            if rowsSource.isIdentical(to: newRows),
               captureSource.isIdentical(to: newCapture),
               newSelection == selection {
                return
            }
            rowsSource = newRows
            captureSource = newCapture
            let previous = rows
            rows = newRows.value
            capture = newCapture.value
            guard let table else { return }
            // Measured here, before the table is touched: whether to follow is a question
            // about *where the operator is standing right now*, and the only honest answer
            // is the viewport's own geometry a moment before the edit lands.
            //
            // The flag this used to gate on was the wrong shape for it. `followTail` could
            // only be turned off by a scroll notification, and the notifications do not
            // cover every way a viewport moves — so it stayed armed through movements
            // nobody was told about and the list yanked itself back down while the operator
            // was reading something further up. There is no bookkeeping to get wrong if
            // nothing is booked: at the bottom, follow; anywhere else, hold still.
            //
            // A glide in flight counts as being at the bottom, and has to: it is *behind*
            // the bottom by construction, so measuring geometry alone would read the list's
            // own catch-up as the operator having scrolled away and stop following in the
            // middle of the movement.
            let visible = isWindowVisible
            let wasAtBottom = Self.shouldFollowTail(
                windowVisible: visible, atBottom: isAtBottom(), gliding: displayLink != nil,
                current: followTail
            )
            isApplyingUpdate = true
            defer { isApplyingUpdate = false }
            let diff = RowDiff(from: previous, to: rows)
            // The structural edit is applied whether or not anyone can see it: the table's
            // own row count has to keep matching `rows`, or the next insert is computed
            // against a count that moved. What is skipped while occluded is everything
            // *visual* — see `apply` and the follow below.
            apply(diff, in: table)
            applySelection(newSelection, in: table)
            guard visible else {
                // Nothing is being shown, so there is nothing to follow and no geometry
                // worth reading. `followTail` is left frozen at its last on-screen value,
                // which is what `windowOcclusionChanged` restores from.
                stopGliding()
                return
            }
            // On the *diff*, not on a row-count change: once the window is at its cap the
            // head is trimmed by exactly what the tail gained, so the count is constant
            // while the list keeps moving — and a count gate silently stops following at
            // the one point where there is the most to follow.
            if wasAtBottom, diff != .none { scrollToBottom() }
            // `followTail` is deliberately **not** written here. It is the operator's
            // answer, re-derived in `viewportDidMove` when they move the viewport;
            // writing it from our own edit is exactly how the follow used to turn itself
            // off after a display-cap trim.
        }

        /// Whether the list should be following the tail after an edit.
        ///
        /// Pure, so the one case that has no geometry to read can be stated rather than
        /// inferred: **while the window is occluded the answer is frozen**. The offset is
        /// deliberately not kept at the bottom then (that is the whole saving), so the
        /// viewport falls behind the growing document and `isAtBottom()` would answer
        /// "no" — flipping the follow off for a reader who never scrolled anywhere, and
        /// leaving the list stuck mid-capture when the window came back.
        /// Whether to keep the list at the tail for this edit.
        ///
        /// **`current` is an input again, and that is a reversal — see the entry in
        /// `Features/AppFeature/CLAUDE.md`.** Geometry alone had no way back: once the
        /// viewport was more than `isAtBottom`'s half-row tolerance behind, every later
        /// edit read "the operator scrolled away" and nothing ever re-armed the follow.
        /// Measured, the list sat **~2 000 pt — 86 rows — behind the newest row and the
        /// gap kept growing**, while the follow control still read as on. The list
        /// silently stopping is worse than the failure the geometry-only rule was
        /// introduced to fix (yanking down while someone reads), because nobody can see
        /// it happen.
        ///
        /// What makes `current` safe this time is *where it comes from*: `viewportDidMove`
        /// re-derives it from geometry every time the viewport actually moves, and
        /// deliberately not when our own edit moved it. The old flag was wrong because
        /// nothing cleared it; this one is cleared by every scroll there is.
        static func shouldFollowTail(
            windowVisible: Bool, atBottom: Bool, gliding: Bool, current: Bool
        ) -> Bool {
            guard windowVisible else { return current }
            // A glide in flight counts as being at the bottom, and has to: it is *behind*
            // the bottom by construction, so measuring geometry alone would read the
            // list's own catch-up as the operator having scrolled away.
            return current || atBottom || gliding
        }

        /// Whether a viewport move is the operator's, and so worth re-deriving the follow
        /// from.
        ///
        /// **A scroll never changes the document's height; our own edits always do.** A
        /// trim shifts the clip view down by the removed height and an append grows the
        /// document under a stationary viewport — both arrive as a bounds change with no
        /// operator involved, and sampling them is what made the follow answer "they
        /// scrolled away" to its own work. No synchronous flag can catch them: the move
        /// lands in the display cycle, long after `update` returned (measured: 549 of 551
        /// of these arrived with `isApplyingUpdate` already false).
        ///
        /// A glide is ours too, and it is behind the bottom by construction.
        static func shouldSampleFollow(documentHeightChanged: Bool, gliding: Bool) -> Bool {
            !documentHeightChanged && !gliding
        }

        /// Whether this table is on a window someone can currently see.
        ///
        /// Not a nicety. Everything the follow does per frame — `setBoundsOrigin` on the
        /// clip view — costs an AppKit KVO walk that reaches **every realized cell**, and
        /// each cell is an `NSHostingView` that answers by invalidating its SwiftUI
        /// layout. Measured on a build capturing ~3 flows/s with the screen locked: the
        /// display link ran continuously and the app held **~70 % of a core** drawing
        /// something no one could see. Occlusion is the honest gate for that — a
        /// minimised, fully covered or locked-screen window reports not-visible, and a
        /// window that is merely in the background does not.
        private var isWindowVisible: Bool {
            guard let window = scrollView?.window else { return false }
            return window.occlusionState.contains(.visible)
        }

        @objc private func windowOcclusionChanged(_ notification: Notification) {
            guard let window = notification.object as? NSWindow, window === scrollView?.window,
                  let table
            else { return }
            guard isWindowVisible else { stopGliding(); return }
            // Coming back. The rows are current — cells are built from `rows` on demand —
            // but nothing on screen was refreshed while away, and the offset was left
            // where the last visible frame put it.
            refreshVisibleRows(in: table)
            // Set rather than glided, for the same reason the initial tail scroll is: a
            // list arriving already at the tail is where it belongs, not something that
            // travelled while the window was being revealed.
            if followTail, mayScrollProgrammatically { setOffsetY(maximumOffsetY) }
        }

        /// Turn a diff into the smallest set of table operations that expresses it, then
        /// refresh what is on screen.
        ///
        /// This used to be `reloadData()` on any change, which is one line and wrong at
        /// this update rate: capture batches land every ~100 ms, and a full reload
        /// discards *every realized cell* — each of which hosts a SwiftUI view — to
        /// rebuild the same rows with the same content. It also cancels any in-flight
        /// scroll and makes an insertion impossible to animate, because from the table's
        /// point of view nothing was inserted; everything was replaced.
        private func apply(_ diff: RowDiff, in table: NSTableView) {
            switch diff {
            case .none:
                break

            case .reload:
                table.reloadData()
                return // reload rebuilds every visible cell already

            case let .edit(removedFromFront, appended):
                // One group: two separate edits would each trigger their own layout pass,
                // and the second would be computed against a row count the first moved.
                table.beginUpdates()
                if removedFromFront > 0 {
                    table.removeRows(at: IndexSet(integersIn: 0 ..< removedFromFront), withAnimation: [])
                }
                if appended > 0 {
                    let start = rows.count - appended
                    table.insertRows(at: IndexSet(integersIn: start ..< rows.count), withAnimation: [])
                }
                table.endUpdates()
            }
            // Pushing content into cells nobody is looking at is the other half of the
            // occluded cost; `windowOcclusionChanged` does one refresh on the way back in.
            if isWindowVisible { refreshVisibleRows(in: table) }
        }

        /// Push current content into every row that is actually on screen.
        ///
        /// Unconditional, and that is the design: working out *which* rows changed costs
        /// a comparison per retained flow, while doing it for all of them costs the
        /// viewport — a few dozen rows whatever the capture holds. `CellContent` is
        /// `Equatable`, so SwiftUI skips the ones whose values didn't move; the work for
        /// an unchanged row is a value compare, not a re-render.
        private func refreshVisibleRows(in table: NSTableView) {
            let visible = table.rows(in: table.visibleRect)
            guard visible.length > 0 else { return }
            for row in visible.location ..< NSMaxRange(visible) {
                refreshCells(atRow: row, in: table)
            }
        }

        /// Update an already-realized row's content **in place**, without asking the
        /// table to rebuild its views.
        ///
        /// This is the common case and the reason it is worth having: an exchange
        /// upserts several times (pending → completed, once per streaming update, once
        /// per WebSocket frame), and every one of those is the same row with new values.
        /// `reloadData(forRowIndexes:)` would discard the row's cells and build new
        /// `NSHostingView`s for them; setting the hosted content instead lets SwiftUI do
        /// what it is good at — diff a view against its previous value — and keeps the
        /// hosting views alive.
        ///
        /// `makeIfNecessary: false` is the load-bearing argument: a row that is not on
        /// screen has no views, and it must *stay* that way. Making them here would
        /// realize a cell per off-screen change, which is the cost the table exists to
        /// avoid.
        private func refreshCells(atRow row: Int, in table: NSTableView) {
            guard rows.indices.contains(row) else { return }
            let flow = rows[row]
            for (index, tableColumn) in table.tableColumns.enumerated() {
                guard let column = Column(rawValue: tableColumn.identifier.rawValue),
                      let cell = table.view(atColumn: index, row: row, makeIfNecessary: false) as? HostingCell
                else { continue }
                cell.host(CellContent(column: column, flow: flow, ordinal: ordinal(of: flow, fallback: row)))
            }
            // The fill is a property of the row, not of a cell, and it moves when an
            // exchange fails or stops failing. Animated here and only here: this row is
            // on screen and its answer just landed.
            if let rowView = table.rowView(atRow: row, makeIfNecessary: false) as? RowView {
                rowView.setFailure(
                    LoomTheme.isFailure(status: flow.statusCode, isError: flow.error != nil),
                    animated: true
                )
            }
        }

        func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

        /// Double-clicking a column divider. `NSTableView` asks for the width and applies
        /// it — including clamping to the column's own min/max, so a fit that would make
        /// Path 4 000 points wide stops where the column says it stops.
        func tableView(_ tableView: NSTableView, sizeToFitWidthOfColumn column: Int) -> CGFloat {
            guard tableView.tableColumns.indices.contains(column) else { return 0 }
            let tableColumn = tableView.tableColumns[column]
            guard let spec = Column(rawValue: tableColumn.identifier.rawValue) else {
                return tableColumn.width
            }
            return RequestTable.fittingWidth(for: spec, rows: rows, capture: capture)
        }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard let tableColumn, let column = Column(rawValue: tableColumn.identifier.rawValue),
                  rows.indices.contains(row)
            else { return nil }
            let flow = rows[row]
            let content = CellContent(column: column, flow: flow, ordinal: ordinal(of: flow, fallback: row))
            if let cell = tableView.makeView(withIdentifier: tableColumn.identifier, owner: self) as? HostingCell {
                cell.host(content)
                return cell
            }
            return HostingCell(identifier: tableColumn.identifier, content: content)
        }

        /// The failed-row fill, native now: `NSTableRowView` is the only thing in this
        /// stack that owns a row-sized rectangle, and asking for it per row is what the
        /// old bridge had to reach through the view tree to do.
        func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
            let rowView = tableView.makeView(withIdentifier: Self.rowViewIdentifier, owner: self) as? RowView
                ?? {
                    let view = RowView()
                    view.identifier = Self.rowViewIdentifier
                    return view
                }()
            let flow = rows.indices.contains(row) ? rows[row] : nil
            let failed = flow.map { LoomTheme.isFailure(status: $0.statusCode, isError: $0.error != nil) } ?? false
            // Not animated: this is a row arriving on screen, which has nothing to
            // announce. The fade belongs to a row already visible whose exchange just
            // failed — see `refreshCells`.
            rowView.setFailure(failed, animated: false)
            return rowView
        }

        /// 1-based position in the capture — an O(1) lookup, done per visible cell.
        private func ordinal(of flow: Flow, fallback row: Int) -> Int {
            (capture.index(id: flow.id) ?? row) + 1
        }

        private static let rowViewIdentifier = NSUserInterfaceItemIdentifier("loom.request.row")

        /// Selection drawn in **Loom's** accent, and the failed-exchange fill drawn as
        /// a layer that can fade.
        ///
        /// Selection: the `Table` this replaces got there with
        /// `.tint(LoomTheme.Palette.accent)`, and DESIGN.md § Colors is why — an
        /// untinted `NSTableView` fills the row with the hue the *user* set in System
        /// Settings, a colour sitting right next to Loom's accent-tinted method glyphs
        /// and disagreeing with them. Drawn at partial opacity rather than as a solid
        /// fill, which is the one deliberate difference from before: SwiftUI inverted a
        /// selected row's label colours for free, and these cells host their own SwiftUI
        /// trees that know nothing about the row's selection state.
        ///
        /// Failure fill: a layer rather than `backgroundColor` so the state *change* can
        /// animate. A row is pending when it first appears and gets its status later —
        /// that is the normal path, not an edge case — so the tint arriving is something
        /// the eye should be able to catch. Popping in between two frames reads as a
        /// glitch; a 200 ms fade reads as the answer landing.
        final class RowView: NSTableRowView {
            /// A subview, not a `CALayer` on this view's own backing layer.
            ///
            /// The layer version compiled, ran, and drew nothing: `wantsLayer = true` in
            /// `init` does not guarantee `layer` is non-nil on the next line, so
            /// `layer?.insertSublayer` silently did nothing and every failed row looked
            /// exactly like a healthy one. A subview has no such window — it is attached
            /// when it is added, and it sits under the cell views because it was added
            /// before them.
            private let failureFill = NSView()
            private var isFailure = false

            override init(frame: NSRect) {
                super.init(frame: frame)
                failureFill.wantsLayer = true
                failureFill.layer?.backgroundColor = LoomTheme.rowFillError.cgColor
                failureFill.alphaValue = 0
                failureFill.autoresizingMask = [.width, .height]
                failureFill.frame = bounds
                addSubview(failureFill)
            }

            @available(*, unavailable)
            required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

            /// Re-assert the colour whenever the appearance changes: a `cgColor` is
            /// resolved once, so a dynamic asset colour captured under one appearance
            /// keeps that appearance until something re-reads it.
            override func updateLayer() {
                super.updateLayer()
                failureFill.layer?.backgroundColor = LoomTheme.rowFillError.cgColor
            }

            override func viewDidChangeEffectiveAppearance() {
                super.viewDidChangeEffectiveAppearance()
                failureFill.layer?.backgroundColor = LoomTheme.rowFillError.cgColor
            }

            /// `animated: false` on first configuration — a row scrolling into view
            /// already-failed has nothing to announce, and fading every recycled row in
            /// would make scrolling shimmer.
            func setFailure(_ failure: Bool, animated: Bool) {
                guard failure != isFailure else { return }
                isFailure = failure
                if animated {
                    NSAnimationContext.runAnimationGroup { context in
                        context.duration = 0.2
                        failureFill.animator().alphaValue = failure ? 1 : 0
                    }
                } else {
                    failureFill.alphaValue = failure ? 1 : 0
                }
            }

            /// Recycling hygiene: a reused row must not inherit its predecessor's state,
            /// and it must not *animate* out of it either — the fill is set fresh, with
            /// no transition, before the row is handed back out.
            override func prepareForReuse() {
                super.prepareForReuse()
                setFailure(false, animated: false)
            }

            override func drawSelection(in dirtyRect: NSRect) {
                guard selectionHighlightStyle != .none else { return }
                let accent = NSColor(LoomTheme.Palette.accent)
                // Emphasized = this table has focus. The unfocused wash is weaker for the
                // same reason AppKit's own is: an inactive selection should not compete
                // with the active one in another pane.
                accent.withAlphaComponent(isEmphasized ? 0.30 : 0.16).setFill()
                dirtyRect.fill()
            }
        }

        // MARK: Selection

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !applyingSelection, let table else { return }
            let row = table.selectedRow
            selection = rows.indices.contains(row) ? rows[row].id : nil
        }

        /// Sync the table's selected row to `id`.
        ///
        /// The early return is the whole point, and it has to be reachable **without
        /// searching `rows`**. This runs on every capture batch — ten times a second —
        /// and the search it guards is a linear walk of the window, which at
        /// `FlowLimits.windowRows` is ~100 000 id comparisons to conclude, almost always,
        /// that nothing moved. That is precisely the shape this file refuses everywhere
        /// else: `ordinal(of:)` takes an O(1) `index(id:)` rather than scan the capture,
        /// and `RowDiff` gives up its alignment search after a bounded window so it can
        /// never cost the capture. This one was scanning it every batch.
        ///
        /// Asking the table where its selection *is* answers in O(1) and is correct at
        /// steady state: `apply` runs first, and `NSTableView` shifts its own selection
        /// index across `removeRows`/`insertRows` — so after a head trim the selected
        /// row still holds the selected flow, at a new index nobody had to find. The
        /// search is kept for the cases where that fails (a `.reload`, or a selection
        /// the store moved), and those are gestures, not traffic.
        private func applySelection(_ id: Flow.ID?, in table: NSTableView) {
            let current = table.selectedRow
            // Already right: either the selected row is the selected flow, or both sides
            // agree there is no selection.
            if current >= 0, rows.indices.contains(current), rows[current].id == id { return }
            if current < 0, id == nil { return }

            let target = id.flatMap { id in rows.firstIndex { $0.id == id } }
            guard target != (current >= 0 ? current : nil) else { return }
            applyingSelection = true
            defer { applyingSelection = false }
            if let target {
                table.selectRowIndexes(IndexSet(integer: target), byExtendingSelection: false)
            } else {
                table.deselectAll(nil)
            }
        }

        // MARK: Tail-follow

        /// Set while a data update is being applied, so the viewport movement that update
        /// causes — a head trim, an insert animation, the tail-follow scroll itself — is
        /// never fed back in as if the operator had scrolled.
        private var isApplyingUpdate = false

        /// The operator taking hold of the list wins over the glide, immediately —
        /// otherwise scrolling up under live capture is a fight for the offset that the
        /// display link wins every frame.
        @objc private func userWillScroll() {
            isLiveScrolling = true
            lastLiveScrollAt = Date()
            stopGliding()
            // An operator who scrolled before the first layout settled has said where they
            // want to be, and it outranks opening at the tail.
            wantsInitialTailScroll = false
        }

        @objc private func userDidEndScroll() {
            isLiveScrolling = false
            userScrolling()
        }

        /// A **live scroll** — the operator's own gesture. Arms the quiet window that
        /// keeps the glide out of their way, and refreshes the readout.
        @objc private func userScrolling() {
            lastLiveScrollAt = Date()
            // Unconditional: this notification *means* the operator, so it re-derives
            // even if a batch changed the document's height during the gesture.
            lastSampledDocumentHeight = documentHeight
            let atBottom = isAtBottom()
            if followTail != atBottom { followTail = atBottom }
        }

        /// The viewport moved, by whatever cause. Keeps `followTail` reporting where it
        /// actually is, and **decides nothing** — which is the fix, not a nicety.
        ///
        /// This used to be `userScrolling`, so every bounds change armed
        /// `lastLiveScrollAt` and put the follow into its quiet window. The guard meant
        /// to exclude the table's own edits (`!isApplyingUpdate, !isGliding`) cannot:
        /// an edit moves the clip view during the *display cycle*, long after `update`
        /// returned and the flag was cleared. Measured under 10 req/s, 549 of 551 of
        /// these arrived with both flags already false and armed the window, so
        /// `mayScrollProgrammatically` was never true again while traffic flowed —
        /// `scrollToBottom` was reached **once**, and blocked. Tail-follow was dead: the
        /// list sat ~1 900 pt (80 rows) behind the newest row and the gap kept growing,
        /// while the follow control still read as on.
        ///
        /// No flag can cover it, because the move is not synchronous with the edit. The
        /// answer is that only the notifications that *mean* "the operator is scrolling"
        /// (`willStartLiveScroll` / `didLiveScroll` / `didEndLiveScroll`) arm anything.
        @objc private func viewportDidMove() {
            let height = documentHeight
            defer { lastSampledDocumentHeight = height }
            guard Self.shouldSampleFollow(
                documentHeightChanged: height != lastSampledDocumentHeight,
                gliding: displayLink != nil
            ) else { return }
            let atBottom = isAtBottom()
            if followTail != atBottom { followTail = atBottom }
        }

        private var documentHeight: CGFloat { scrollView?.documentView?.frame.height ?? 0 }

        /// The document height at the last sample, so a move can be attributed. See
        /// `shouldSampleFollow`.
        private var lastSampledDocumentHeight: CGFloat = 0

        /// Whether a scroll gesture is in progress, and when the viewport last moved for a
        /// reason that was not this table's own doing.
        ///
        /// Both exist because **the glide and a live scroll write the same clip view**, and
        /// a column dragged wide enough to scroll horizontally is where that shows: the
        /// gesture moves x, a capture batch lands mid-gesture and the display link starts
        /// writing y, and the two settings of `boundsOrigin` interleave every frame — the
        /// list shakes. Scrolling vertically hid it, because there the glide was pushing
        /// the same axis in the same direction the reader was already going.
        private var isLiveScrolling = false
        private var lastLiveScrollAt: Date?

        /// How long after the last viewport move the follow stays out of the way.
        ///
        /// `didEndLiveScroll` fires when the fingers lift and momentum keeps going after
        /// it, so ending the suppression there would put the fight back for the length of
        /// the deceleration. The cost of the window is at most a few skipped batches, and
        /// the follow catches up in one glide when it resumes — the list is never left
        /// somewhere it did not choose to be.
        static let scrollQuietWindow: TimeInterval = 0.5

        /// Whether the follow may take the offset right now.
        private var mayScrollProgrammatically: Bool {
            guard !isLiveScrolling else { return false }
            guard let lastLiveScrollAt else { return true }
            return Date().timeIntervalSince(lastLiveScrollAt) >= Self.scrollQuietWindow
        }

        /// A row scrolled halfway off the bottom means the operator is not at the bottom.
        ///
        /// Measured against the scroll geometry rather than `rows(in:)`, which counts a
        /// row as visible when *any* of it is — so the last row peeking in by a pixel read
        /// as "at the bottom" and the list followed while the operator was reading the row
        /// above it.
        private func isAtBottom() -> Bool {
            guard let scrollView, let document = scrollView.documentView else { return true }
            let visible = scrollView.contentView.documentVisibleRect
            guard document.frame.height > visible.height else { return true } // content fits
            return visible.maxY >= document.frame.height - RequestTable.rowHeight / 2
        }

        // MARK: The tail-follow scroll

        /// The follow is a *glide*, driven frame by frame, rather than a jump per batch.
        ///
        /// `scrollRowToVisible` is what this replaces and it is what made a busy list
        /// blink: a capture batch inserted its rows and then moved the viewport by the
        /// whole batch in one step, ten times a second, so the content never appeared to
        /// travel — it teleported, and the row-insert fade layered over the top of that
        /// turned into a shimmer (the fade is gone too, for the same reason: the motion
        /// belongs to the scroll, and asking a row to animate as well is two answers to
        /// one question).
        ///
        /// So nothing here scrolls *by* an amount. The link runs while there is distance
        /// left to the bottom and closes a fixed fraction of it per frame — which means a
        /// batch landing mid-glide simply moves the target, and the motion carries through
        /// it instead of restarting.
        private var displayLink: CADisplayLink?

        /// Set while the link is writing the offset, so the bounds-change notification it
        /// causes is not read back as the operator scrolling.
        private var isGliding = false

        /// The list opens **at the newest row**, and getting there is not one call.
        ///
        /// The window's first rows arrive before this view has a size — `documentView` is
        /// zero-height, so the bottom is offset 0 and scrolling to it succeeds at doing
        /// nothing. Every later batch then finds the viewport at the top, which is not the
        /// bottom, and correctly declines to follow: the list opens on the *oldest*
        /// exchange in the capture and stays there.
        ///
        /// So the intent outlives the failed attempt. It is satisfied on the first layout
        /// that has somewhere to scroll to, and unlike the follow itself it is set rather
        /// than glided — a list arriving already scrolled is where it belongs, not
        /// something that travelled.
        private var wantsInitialTailScroll = true

        func scrollViewDidLayout() {
            layoutColumns()
            guard wantsInitialTailScroll, !rows.isEmpty, maximumOffsetY > 0 else { return }
            wantsInitialTailScroll = false
            setOffsetY(maximumOffsetY)
        }

        // MARK: Column widths

        /// True while `layoutColumns` is writing widths, so the resize notifications it
        /// causes are not mistaken for the operator dragging a divider.
        private var isLayingOutColumns = false

        /// Columns the operator has sized by hand. Their width is theirs from then on — the
        /// spare width goes around them. Deliberately not persisted: a column width is a
        /// property of the window someone is looking at, and `hiddenColumns` is the one piece
        /// of table state that has to survive a relaunch (an invisible column is unexplainable
        /// after one; a width is self-evident).
        private var handSizedColumns: Set<Column> = []

        @objc private func columnDidResize(_ note: Notification) {
            guard !isLayingOutColumns,
                  let column = note.userInfo?["NSTableColumn"] as? NSTableColumn,
                  let spec = Column(rawValue: column.identifier.rawValue)
            else { return }
            handSizedColumns.insert(spec)
        }

        /// Give the window's spare width to Host and Path, and leave nothing at the right.
        ///
        /// Runs on every layout of the scroll view, which is what a window resize produces.
        /// The arithmetic is deliberately *read back* rather than predicted: the table's own
        /// width after a retile accounts for intercell spacing and for AppKit's rounding, and
        /// the sink closes whatever difference is left. Predicting it means a column that
        /// misses the trailing edge by two points on some future AppKit.
        func layoutColumns() {
            guard let table, let scrollView, !isLayingOutColumns else { return }
            let available = scrollView.contentView.bounds.width
            guard available > 0 else { return }

            let specs = table.tableColumns.compactMap { column -> (Column, NSTableColumn)? in
                guard !column.isHidden, let spec = Column(rawValue: column.identifier.rawValue)
                else { return nil }
                return (spec, column)
            }
            guard let sink = RequestTable.slackSink(among: specs.map(\.0)),
                  let sinkColumn = specs.first(where: { $0.0 == sink })?.1,
                  let lastVisible = table.tableColumns.lastIndex(where: { !$0.isHidden })
            else { return }

            isLayingOutColumns = true
            defer { isLayingOutColumns = false }

            // A cap on the sink is a gap on the right, so the sink's own `maxWidth` is lifted
            // while it holds that role and put back when it doesn't. This only ever matters
            // with Path hidden — Path's cap is nominal — and it has to be a real write,
            // because `NSTableColumn` clamps `width` against `maxWidth` on assignment rather
            // than letting a caller mean it.
            for (spec, column) in specs where spec == .host {
                column.maxWidth = sink == .host ? .greatestFiniteMagnitude : spec.maxWidth
            }

            var hostColumn: NSTableColumn?
            if sink != .host, !handSizedColumns.contains(.host),
               let host = specs.first(where: { $0.0 == .host })?.1 {
                let others = specs
                    .filter { $0.0 != .host && $0.0 != sink }
                    .reduce(0) { $0 + $1.1.width }
                host.width = RequestTable.hostWidth(slack: available - others)
                hostColumn = host
            }

            /// Move the sink onto the trailing edge, and report what it could not absorb.
            ///
            /// The measurement is the trailing edge of the last visible column, **not**
            /// `table.frame.width`: a scroll view stretches its document view to the viewport,
            /// so the frame reports the width the table was *given* rather than the width its
            /// columns occupy, and a gap computed from it is always zero — which is how the
            /// first version of this shipped a no-op that looked right. `rect(ofColumn:)`
            /// includes intercell spacing and the inset style's edge insets, so it is measured
            /// rather than summed.
            func closeGap() -> CGFloat {
                table.tile()
                let gap = available - table.rect(ofColumn: lastVisible).maxX
                // Sub-point differences are AppKit's own rounding, and chasing them would
                // write a width on every layout pass for no visible change.
                if abs(gap) > 0.5 {
                    // Never under the minimum — past that a column stops showing its content.
                    sinkColumn.width = max(sinkColumn.width + gap, sink.minWidth)
                    table.tile()
                }
                return available - table.rect(ofColumn: lastVisible).maxX
            }

            // Anything still hanging past the trailing edge means the sink is on its floor and
            // the window is narrower than the columns want. Host gives its share back before
            // the table starts scrolling: Path's minimum is the width its content needs, while
            // Host's share is only a preference about where spare room goes.
            if closeGap() < -0.5, let hostColumn {
                hostColumn.width = max(hostColumn.width + (available - table.rect(ofColumn: lastVisible).maxX),
                                       Column.host.minWidth)
                _ = closeGap()
            }
        }

        /// Time constant of the glide: the distance remaining decays by `1/e` this often.
        /// Small enough that the list stays visibly pinned to the tail under load, long
        /// enough that a single row arriving reads as movement.
        static let glideTimeConstant: TimeInterval = 0.08

        /// Beyond this much distance the glide is not worth watching — the list is being
        /// filled or the operator jumped a long way — so the offset is simply set. Two
        /// viewports is about where travelling stops reading as travelling and starts
        /// reading as a smear.
        static let maximumGlideDistance: CGFloat = 2

        private func scrollToBottom() {
            guard let scrollView, let table, table.numberOfRows > 0 else { return }
            // The reader owns the offset while they are moving it. Anything written here
            // during a gesture interleaves with theirs frame by frame.
            guard mayScrollProgrammatically else { stopGliding(); return }
            let clipView = scrollView.contentView
            let remaining = maximumOffsetY - clipView.bounds.origin.y
            switch Self.tailCatchUp(remaining: remaining, viewportHeight: clipView.bounds.height) {
            case .snap:
                setOffsetY(maximumOffsetY)
                stopGliding()
            case .glide:
                startGliding()
            }
        }

        /// How to close the distance to the bottom after an edit.
        ///
        /// `remaining <= 0` snaps rather than returning. The display cap trims
        /// `CaptureFeature.State.trimSlack` (500) rows at once, so a batch can make the
        /// document 12 000 pt shorter and AppKit shifts the clip view's origin down by
        /// the removed height instead of clamping it to the new bottom — the offset ends
        /// up *past* the end. Doing nothing there left the viewport short of the bottom.
        ///
        /// This is not what latched the follow off (that is `viewportDidMove`), but the
        /// two entry points disagreed: `glide` has always handled the same case ("anything
        /// negative means the content shrank under the glide"), and this one did not.
                static func tailCatchUp(remaining: CGFloat, viewportHeight: CGFloat) -> TailCatchUp {
            // Past the end (a trim) or too far to be worth animating: go there directly.
            guard remaining > 0, remaining <= maximumGlideDistance * viewportHeight else {
                return .snap
            }
            return .glide
        }

        /// Snap straight to the bottom, or animate the remaining distance.
        enum TailCatchUp: Equatable { case snap, glide }

        /// The largest vertical offset the clip view can hold — recomputed every frame
        /// rather than captured when the glide starts, because the content is still
        /// growing underneath it and a target fixed at the start would land short.
        private var maximumOffsetY: CGFloat {
            guard let scrollView, let document = scrollView.documentView else { return 0 }
            return max(0, document.frame.height - scrollView.contentView.bounds.height)
        }

        private func startGliding() {
            guard displayLink == nil, let scrollView else { return }
            // A view-owned link, so it runs on the display the window is actually on and
            // stops with it — a `Timer` would keep firing at a rate unrelated to the
            // screen and tear against it.
            let link = scrollView.displayLink(target: self, selector: #selector(glide))
            link.add(to: .main, forMode: .common)
            displayLink = link
        }

        func stopGliding() {
            displayLink?.invalidate()
            displayLink = nil
        }

        @objc private func glide(_ link: CADisplayLink) {
            guard let scrollView else { stopGliding(); return }
            // Checked per frame, not only when the glide starts: a gesture can begin
            // mid-glide, and the frame after it does is already a fight for the offset.
            guard mayScrollProgrammatically else { stopGliding(); return }
            let clipView = scrollView.contentView
            let current = clipView.bounds.origin.y
            let remaining = maximumOffsetY - current
            // Half a point is under a pixel on every display this runs on, so there is
            // nothing left to show; anything negative means the content shrank under the
            // glide and the offset is already past the end.
            guard remaining > 0.5 else {
                setOffsetY(maximumOffsetY)
                stopGliding()
                return
            }
            // Frame-rate independent: the same fraction of distance per unit *time*, not
            // per frame, so a 120 Hz display and a 60 Hz one glide at the same speed.
            let frameDuration = max(link.targetTimestamp - link.timestamp, 1.0 / 120)
            let closed = 1 - exp(-frameDuration / Self.glideTimeConstant)
            setOffsetY(current + remaining * closed)
        }

        private func setOffsetY(_ y: CGFloat) {
            guard let scrollView else { return }
            isGliding = true
            defer { isGliding = false }
            let clipView = scrollView.contentView
            clipView.setBoundsOrigin(CGPoint(x: clipView.bounds.origin.x, y: y))
            // Without this the scroller thumb and the clip view disagree: the rows move
            // and the scrollbar stays where it was.
            scrollView.reflectScrolledClipView(clipView)
        }

        // MARK: Context menu

        /// Built once and re-titled on open. `clickedRow` is what a right-click targets
        /// — deliberately not the selection, so right-clicking a row acts on *that* row
        /// whether or not it is selected, which is the platform behaviour.
        func makeRowMenu() -> NSMenu {
            let menu = NSMenu()
            menu.delegate = self
            return menu
        }

        /// The header's column chooser. Rebuilt on open rather than kept in sync, because
        /// a column can also be hidden from the previous launch's defaults and the menu is
        /// the only surface that reads that back.
        func makeHeaderMenu() -> NSMenu {
            let menu = NSMenu()
            menu.delegate = self
            menu.identifier = Self.headerMenuIdentifier
            return menu
        }

        private static let headerMenuIdentifier = NSUserInterfaceItemIdentifier("loom.table.headerMenu")

        private func buildHeaderMenu(_ menu: NSMenu) {
            menu.removeAllItems()
            guard let table else { return }
            let visibleCount = table.tableColumns.count(where: { !$0.isHidden })
            for tableColumn in table.tableColumns {
                guard let spec = Column(rawValue: tableColumn.identifier.rawValue) else { continue }
                let entry = item(spec.menuTitle) { [weak self] in
                    self?.toggleColumn(spec)
                }
                entry.state = tableColumn.isHidden ? .off : .on
                // Hiding the last visible column leaves a blank rectangle whose only way
                // back is a header that no longer draws anything.
                entry.isEnabled = tableColumn.isHidden || visibleCount > 1
                menu.addItem(entry)
            }
        }

        private func toggleColumn(_ spec: Column) {
            guard let table,
                  let tableColumn = table.tableColumns.first(where: { $0.identifier == spec.identifier })
            else { return }
            tableColumn.isHidden.toggle()
            var hidden = Column.hiddenColumns()
            if tableColumn.isHidden { hidden.insert(spec) } else { hidden.remove(spec) }
            Column.setHiddenColumns(hidden)
            // Hiding a column frees its width and unhiding one spends width the sink was
            // holding; either way the trailing edge has just moved, and no scroll-view layout
            // is coming to notice it.
            layoutColumns()
        }

        private var clickedFlow: Flow? {
            guard let table, rows.indices.contains(table.clickedRow) else { return nil }
            return rows[table.clickedRow]
        }

        func menuNeedsUpdate(_ menu: NSMenu) {
            guard menu.identifier != Self.headerMenuIdentifier else {
                buildHeaderMenu(menu)
                return
            }
            menu.removeAllItems()
            guard let flow = clickedFlow else { return }
            let id = flow.id
            let host = MainView.host(flow.request.url)

            // A CONNECT row is not an exchange: there is no request to replay, no body
            // to copy and no rule worth stamping from it. It has the scope items and
            // its name, and *which* scope item is the whole difference between its two
            // kinds — which wear the same lock and mean opposite things.
            //
            // A **relayed** tunnel is a host nobody named: under a whitelist that is
            // the ordinary state, this row is how the operator meets the origin at all,
            // and Decrypt is the point of the row. A **failed** one is a host Loom is
            // already trying to decrypt, so the repair is the opposite write. Neither
            // is read off the row — `scopeItems` asks the scope, and the two predicates
            // are complementary by construction.
            switch FlowEncryption(flow) {
            case .tunnelled, .decryptionFailed:
                for entry in scopeItems(for: flow, host: host) { menu.addItem(entry) }
                menu.addItem(.separator())
                menu.addItem(item("Don't Capture \(host)", image: "eye.slash") { [onAddRule] in
                    onAddRule(id, .dropCaptureHost)
                })
                menu.addItem(.separator())
                menu.addItem(item("Copy Host") { MainView.copy(host) })
                return
            case .decrypted, .plaintext:
                break
            }

            menu.addItem(item("Replay", image: "arrow.triangle.2.circlepath") { [onReplay] in onReplay(id) })
            menu.addItem(.separator())

            let copy = NSMenu()
            copy.addItem(item("Host") { MainView.copy(host) })
            copy.addItem(item("Path") { MainView.copy(MainView.path(flow.request.url)) })
            copy.addItem(item("URL") { MainView.copy(flow.request.url) })
            copy.addItem(.separator())
            copy.addItem(item("as cURL") { [onCopyCurl] in onCopyCurl(id) })
            let copyItem = NSMenuItem(title: "Copy", action: nil, keyEquivalent: "")
            copyItem.submenu = copy
            menu.addItem(copyItem)

            let rules = NSMenu()
            let mock = item("Mock This Response") { [onAddRule] in onAddRule(id, .mockResponse) }
            mock.isEnabled = flow.response != nil
            rules.addItem(mock)
            rules.addItem(.separator())
            rules.addItem(item("Block This URL") { [onAddRule] in onAddRule(id, .blockURL) })
            rules.addItem(item("Block Host \(host)") { [onAddRule] in onAddRule(id, .blockHost) })
            rules.addItem(.separator())
            // Beside the blocks because it is a rule like they are, and separated from
            // them because it is the one that does *not* touch the traffic: the request
            // still happens, Loom just stops keeping it.
            rules.addItem(item("Don't Capture \(host)") { [onAddRule] in onAddRule(id, .dropCaptureHost) })
            let rulesItem = NSMenuItem(title: "Add Rule", action: nil, keyEquivalent: "")
            rulesItem.submenu = rules
            menu.addItem(rulesItem)

            let scope = scopeItems(for: flow, host: host)
            if !scope.isEmpty {
                menu.addItem(.separator())
                for entry in scope { menu.addItem(entry) }
            }
        }

        /// The scope write this row makes available — empty when neither would change
        /// anything.
        ///
        /// **Exactly one direction is ever offered**, because the scope answers the
        /// question for us: a host it decrypts can only be passed through, one it does
        /// not can only be decrypted. Deriving it from the row instead (its glyph, its
        /// error, its scheme) is how a menu comes to offer a write that silently does
        /// nothing — a replayed flow, a HAR import and a reverse-proxy flow all carry
        /// an `https://` URL for a host the scope may have nothing to say about.
        ///
        /// Two grains each, because a service is usually several sub-domains of one
        /// apex and doing them one at a time is one click *and* one re-run of the
        /// client per sub-domain.
        private func scopeItems(for flow: Flow, host: String) -> [NSMenuItem] {
            let wildcard = Self.parentWildcard(for: host)
            if Self.offersExclude(flow.request.url, scope: sslScope) {
                var items = [item("Pass Through \(host)", image: "lock") { [onExcludeHost] in
                    onExcludeHost(host)
                }]
                if let wildcard {
                    items.append(item("Pass Through \(wildcard)", image: "lock") { [onExcludeHost] in
                        onExcludeHost(wildcard)
                    })
                }
                return items
            }
            guard Self.offersDecrypt(flow.request.url, scope: sslScope) else { return [] }
            var items = [item("Decrypt \(host)", image: "lock.open") { [onDecryptHost] in
                onDecryptHost(host)
            }]
            if let wildcard {
                items.append(item("Decrypt \(wildcard)", image: "lock.open") { [onDecryptHost] in
                    onDecryptHost(wildcard)
                })
            }
            return items
        }

        /// One level up from a host, as a glob — `api.test.example.com` →
        /// `*.test.example.com`. `nil` when there is no safe answer.
        ///
        /// **One label, not "the registrable domain".** Getting to `*.example.com` from
        /// `api.test.example.com` needs a public-suffix list, and guessing it with "keep
        /// the last two labels" answers `*.co.uk` for `shop.example.co.uk` — a glob that
        /// stops decrypting a country. Dropping exactly one label can only ever widen
        /// the carve-out by one level, which is the same thing the operator would have
        /// typed.
        ///
        /// Two hosts still have no answer: fewer than three labels (`example.com` would
        /// give `*.com`) and anything that looks like an IP address (`10.0.12.93` would
        /// give `*.0.12.93`, which matches nothing and reads like it should).
        ///
        /// The remaining hazard — a three-label host on a multi-label suffix, where
        /// `example.co.uk` does yield `*.co.uk` — is answered by the menu *item*, which
        /// spells the glob out. The operator reads what they are about to pass through
        /// before clicking it, and the write is one line removed from the console's
        /// "Passed through" list from being undone.
        static func parentWildcard(for host: String) -> String? {
            let labels = host.split(separator: ".", omittingEmptySubsequences: false)
            guard labels.count >= 3, labels.allSatisfy({ !$0.isEmpty }) else { return nil }
            // An IPv4 address has the shape but none of the meaning. IPv6 never reaches
            // here — it has no dots — and neither does a host with a port, which the
            // caller has already stripped.
            guard labels.contains(where: { !$0.allSatisfy(\.isNumber) }) else { return nil }
            return "*." + labels.dropFirst().joined(separator: ".")
        }

        /// Whether "pass this host through" would change anything for this row.
        ///
        /// Two conditions, and both are needed. **The exchange must be TLS** — on a
        /// plain `http://` row the scope decides nothing, so the item would be a
        /// control that silently does nothing. That half is answered from the *scheme*
        /// rather than from `FlowTransport`, because an absent transport means
        /// unmeasured, not plaintext (AGENTS.md § FlowTransport), so reading it here
        /// would hide the item on a flow that was mocked or is still in flight;
        /// `wss://` counts, being a TLS handshake Loom terminated like any other.
        ///
        /// **And the scope must currently decrypt the host.** Scheme alone was the
        /// first version and it offered the item on every TLS row — including replayed
        /// flows, HAR imports and reverse-proxy flows (whose recorded URL is the
        /// upstream `https://` one while the inbound hop is plaintext), where the host
        /// may already be excluded. The write then changed nothing while the console
        /// reported a fresh success.
        static func offersExclude(_ url: String, scope: SSLScope) -> Bool {
            guard isTLS(url) else { return false }
            return scope.shouldIntercept(host: MainView.host(url))
        }

        /// The inverse, and the primary write under a whitelist: a TLS host the scope
        /// does **not** decrypt. This is how a host enters the whitelist from the
        /// table — the relayed `CONNECT` row is where the operator meets the origin at
        /// all, so a row with no Decrypt on it is a dead end.
        ///
        /// Complementary with `offersExclude` by construction: both require TLS and
        /// they split on the same `shouldIntercept`, so no row can offer both and no
        /// TLS row can offer neither.
        static func offersDecrypt(_ url: String, scope: SSLScope) -> Bool {
            guard isTLS(url) else { return false }
            return !scope.shouldIntercept(host: MainView.host(url))
        }

        private static func isTLS(_ url: String) -> Bool {
            let lower = url.lowercased()
            return lower.hasPrefix("https://") || lower.hasPrefix("wss://")
        }

        /// A menu item carrying its own action. `NSMenuItem` predates closures and
        /// wants a target/selector pair; `ActionItem` is the one small shim rather than
        /// a selector per menu entry.
        private func item(_ title: String, image: String? = nil, action: @escaping () -> Void) -> NSMenuItem {
            let menuItem = ActionItem(title: title, action: action)
            if let image { menuItem.image = NSImage(systemSymbolName: image, accessibilityDescription: nil) }
            return menuItem
        }

        private final class ActionItem: NSMenuItem {
            private let handler: () -> Void

            init(title: String, action: @escaping () -> Void) {
                handler = action
                super.init(title: title, action: #selector(fire), keyEquivalent: "")
                target = self
            }

            @available(*, unavailable)
            required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

            @objc private func fire() { handler() }
        }
    }
}

/// What changed between two row sets, in the vocabulary `NSTableView` speaks.
///
/// Not a general diff, deliberately. A general LCS over 20 000 rows on every capture
/// batch would cost more than the reload it replaces, and it would be solving a problem
/// this list doesn't have: the capture is a **log**. It grows at the tail, it is trimmed
/// at the head when the window cap bites, and individual rows change in place as
/// exchanges progress. Those three shapes — and their combinations — are what this
/// recognises; anything else (a category switch, a needle typed, a clear) is a different
/// list and says so.
///
/// The reason to bother: a reload discards every realized cell, each of which hosts a
/// SwiftUI view, and rebuilds it with identical content. At ~10 updates a second that is
/// the table's whole cost.
enum RowDiff: Equatable {
    case none
    /// A different list. Rebuild.
    case reload
    /// The same list, edited: `removedFromFront` rows trimmed at the head and
    /// `appended` added at the tail.
    case edit(removedFromFront: Int, appended: Int)

    /// How far into the old rows the alignment search will look before giving up.
    ///
    /// The head only ever moves by what one batch trimmed, so the answer is a handful.
    /// A bound is what keeps this O(1) instead of O(capture): an unbounded search over a
    /// list that turns out to be unrelated walks every row to conclude nothing.
    static let maxAlignmentSearch = 512

    /// Structure only — **not content**.
    ///
    /// This deliberately does not work out which rows *changed*, and that is what makes
    /// it cheap. The first version compared `Flow` values across the whole overlap to
    /// find them, which is a full value comparison per retained row on every capture
    /// batch: measured at 20 000 rows it was the dominant cost of the update, and it
    /// scaled with the capture — the one thing this table must not do.
    ///
    /// It is unnecessary because content correctness comes from somewhere cheaper. Cells
    /// are built from the current rows on demand, so an off-screen row is right the
    /// moment it scrolls into view whatever happened while it was away, and the on-screen
    /// ones are refreshed unconditionally after every edit (`refreshVisibleRows`) — which
    /// costs the viewport, not the capture. So the only thing structure has to get right
    /// is the row *count*.
    init(from old: [Flow], to new: [Flow]) {
        if old.isEmpty, new.isEmpty { self = .none; return }
        if old.isEmpty || new.isEmpty { self = .reload; return }

        // Where the new list's first row sits in the old one — i.e. how many rows came
        // off the head. `nil` means these lists share no anchor and it is a different
        // list (a category tap, a needle, a clear).
        let searchWindow = old.prefix(Self.maxAlignmentSearch)
        guard let offset = searchWindow.firstIndex(where: { $0.id == new[0].id }) else {
            self = .reload
            return
        }
        let survivors = old.count - offset
        let appended = new.count - survivors
        // A shrinking tail is not a shape the capture produces; rather than invent an
        // edit for it, rebuild.
        guard appended >= 0 else { self = .reload; return }
        if offset == 0, appended == 0 { self = .none; return }
        self = .edit(removedFromFront: offset, appended: appended)
    }
}

/// One cell's SwiftUI content, chosen by column.
///
/// The cell bodies are unchanged from the `Table` this replaces — same views, fonts and
/// tints — because what moved down a layer is who owns the rows, not what a row looks
/// like. DESIGN.md governs this, and it should keep governing one idiom.

/// Whether Loom read this exchange's contents, for the request table's lock column.
///
/// Derived from the typed tunnel diagnostic. Legacy CONNECT rows are projected by
/// `Flow.effectiveTunnelDiagnostic`, so old captures keep the same rendering without
/// making the method string the model for new traffic.
///
/// **Three answers about decryption, and the third is why this is not a `Bool`.**
/// Succeeded, failed and deliberately-not-attempted are different events with
/// different repairs, and the first version drew the last two identically: a host
/// whose client refused Loom's leaf looked exactly like a host somebody had carved
/// out on purpose, which is the more misleading direction — a deliberate
/// pass-through is the configuration working, a refusal is a request that never
/// happened. `.plaintext` is a fourth *row* state but not a fourth answer to this
/// question: there was nothing to decrypt, so none of the three apply.
enum FlowEncryption {
    /// TLS Loom terminated: the request and response below are plaintext because Loom
    /// decrypted them.
    case decrypted
    /// Loom tried to decrypt and the connection failed — the client refused Loom's
    /// leaf, or the intercepted codec could not read it. Unlike `tunnelled`, the
    /// request never reached the origin: this row is a *broken* request, not an
    /// opaque one.
    case decryptionFailed
    /// A relayed tunnel, by decision. The row is the whole record — there is no body,
    /// because these bytes went past Loom encrypted — but the request itself worked.
    case tunnelled
    /// Plain HTTP. Nothing was encrypted, so nothing was decrypted; drawn differently
    /// from `tunnelled` because "Loom read it" and "Loom couldn't" are opposite answers.
    case plaintext

    init(_ flow: Flow) {
        if let diagnostic = flow.effectiveTunnelDiagnostic {
            switch diagnostic.reason {
            case .clientHandshakeFailed?, .protocolError?:
                self = .decryptionFailed
            default:
                self = flow.error == nil ? .tunnelled : .decryptionFailed
            }
            return
        }
        let url = flow.request.url.lowercased()
        self = url.hasPrefix("https://") || url.hasPrefix("wss://") ? .decrypted : .plaintext
    }

    var glyph: String {
        switch self {
        case .decrypted: "lock.open.fill"
        case .decryptionFailed: "lock.trianglebadge.exclamationmark"
        case .tunnelled: "lock.fill"
        case .plaintext: "lock.slash"
        }
    }

    /// The lock is the *traffic's* state, not Loom's: a closed lock means these bytes
    /// stayed encrypted to Loom, an open one means Loom opened them. Reading it the
    /// other way round — a lock for "secure" — would put the reassuring glyph on the
    /// row whose contents are missing.
    ///
    /// Two chromatic states: success-green when Loom read the exchange, warning
    /// when it tried and the connection failed. A pass-through stays ink — that is
    /// the configuration working, and tinting it too is how a colour stops being
    /// read.
    /// **Derived from `paletteTint`, never a second switch.** A hierarchical style
    /// is not a `Color`, so what a test can read back is the palette half — and a
    /// separate `switch` here is one a test cannot see, i.e. exactly where "which
    /// state is green" would drift away from what ships.
    var tint: AnyShapeStyle {
        if let paletteTint { return AnyShapeStyle(paletteTint) }
        return switch self {
        case .tunnelled: AnyShapeStyle(.secondary)
        case .plaintext: AnyShapeStyle(.quaternary)
        // Unreachable: both chromatic states are answered above.
        case .decrypted, .decryptionFailed: AnyShapeStyle(.secondary)
        }
    }

    /// The two states that spend a palette hue; nil is hierarchical ink, whose
    /// weight `tint` decides.
    var paletteTint: Color? {
        switch self {
        case .decrypted: LoomTheme.Palette.success
        case .decryptionFailed: LoomTheme.Palette.warning
        case .tunnelled, .plaintext: nil
        }
    }

    var help: String {
        switch self {
        case .decrypted: "Decrypted — Loom read this exchange"
        case .decryptionFailed:
            "Decryption failed — the request never reached the origin. Right-click to pass this host through."
        case .tunnelled:
            "Not decrypted — relayed encrypted, so this row is the whole record. Right-click to decrypt this host, then run the client again."
        case .plaintext: "Plain HTTP — nothing to decrypt"
        }
    }
}

private struct CellContent: View, Equatable {
    let column: RequestTable.Column
    let flow: Flow
    let ordinal: Int

    /// Equal when the *drawn* result would be equal — not when the flows are.
    ///
    /// Synthesised conformance would compare whole `Flow` values, which means the header
    /// arrays and every field no column reads, on every visible row after every batch.
    /// What a cell draws is a short list, and comparing exactly that list is both cheaper
    /// and more honest about when a redraw is owed. A field added to a column belongs
    /// here too — the failure mode of forgetting is a cell that stops updating, so this
    /// deliberately reads as a checklist against `body` below.
    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.column == rhs.column
            && lhs.ordinal == rhs.ordinal
            && lhs.flow.id == rhs.flow.id
            && lhs.flow.statusCode == rhs.flow.statusCode
            && lhs.flow.durationMS == rhs.flow.durationMS
            && (lhs.flow.error == nil) == (rhs.flow.error == nil)
            && lhs.flow.request.method == rhs.flow.request.method
            && lhs.flow.request.url == rhs.flow.request.url
            && lhs.flow.sourceApp?.groupingKey == rhs.flow.sourceApp?.groupingKey
            && lhs.flow.replayedFrom == rhs.flow.replayedFrom
            && lhs.flow.importedFrom == rhs.flow.importedFrom
            && lhs.flow.appliedRules?.count == rhs.flow.appliedRules?.count
            && lhs.flow.webSocketMessages?.count == rhs.flow.webSocketMessages?.count
            && lhs.flow.response?.httpVersion == rhs.flow.response?.httpVersion
            && lhs.flow.request.httpVersion == rhs.flow.request.httpVersion
    }

    /// Both HTTP versions, labelled. They routinely disagree — Loom re-originates
    /// every exchange as HTTP/1.1 — and the tooltip used to give only the upstream
    /// one, which reads as a flat contradiction of an h2 client.
    private static func protocolHelp(_ flow: Flow) -> String {
        var parts: [String] = []
        if let client = flow.request.httpVersion { parts.append("Client: \(client)") }
        if let upstream = flow.response?.httpVersion { parts.append("Upstream: \(upstream)") }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        switch column {
        case .status:
            StatusDot(flow: flow).frame(maxWidth: .infinity, alignment: .center)

        case .ordinal:
            Text(verbatim: RequestTable.ordinalLabel(ordinal))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .trailing)

        case .app:
            AppIconView(app: flow.sourceApp)
                .help(flow.sourceApp?.name ?? "Unknown app")

        case .lock:
            // Three states, and the middle one is the reason this column exists: a
            // relayed tunnel produces a row with no body, which is otherwise
            // indistinguishable from an exchange whose body Loom simply lost.
            let encryption = FlowEncryption(flow)
            Image(systemName: encryption.glyph)
                .font(LoomTheme.Icon.badge)
                .foregroundStyle(encryption.tint)
                .help(encryption.help)
                .frame(maxWidth: .infinity, alignment: .center)

        case .proto:
            Text(MainView.protocolLabel(flow))
                .font(.callout.monospaced())
                .foregroundStyle(.secondary)
                // The column is the scheme; the tooltip is the two HTTP versions,
                // which are two different facts (see `protocolLabel`) — what the
                // client negotiated, and what Loom's own upstream hop spoke.
                .help(Self.protocolHelp(flow))
                .frame(maxWidth: .infinity, alignment: .leading)

        case .method:
            Text(flow.request.method)
                .font(.callout.monospaced())
                .foregroundStyle(LoomTheme.methodColor(flow.request.method))
                .frame(maxWidth: .infinity, alignment: .leading)

        case .host:
            // One parse per row, shared by the favicon and the label — they want
            // different readings of it. The favicon keys on the port-less host, so two
            // dev-server ports on one machine share an icon and one cache entry; the
            // label spells a non-default port out, because `10.0.34.87:3762` and `:3862`
            // are otherwise the same row of text.
            let reading = MainView.hostReading(flow.request.url)
            HStack(spacing: 6) {
                FaviconView(host: reading.key)
                Text(reading.label)
                    .font(.callout.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

        case .path:
            HStack(spacing: LoomTheme.Space.xs) {
                Text(MainView.path(flow.request.url))
                    .font(.callout.monospaced())
                    .lineLimit(1)
                    .truncationMode(.middle)
                if flow.replayedFrom != nil {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.caption2)
                        .foregroundStyle(LoomTheme.Palette.accent)
                }
                // Loaded from a file, not seen on this machine's wire. Marked for the
                // same reason a replay is: the row would otherwise read as something
                // that just happened here.
                if let importedFrom = flow.importedFrom {
                    Image(systemName: "tray.and.arrow.down")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .help("Imported from \(importedFrom)")
                }
                if let applied = flow.appliedRules, !applied.isEmpty {
                    Image(systemName: "wand.and.stars")
                        .font(.caption2)
                        .foregroundStyle(LoomTheme.Palette.accent)
                        .help("Modified by rules: \(applied.map(\.name).joined(separator: ", "))")
                }
                if flow.isWebSocket {
                    Image(systemName: "bolt.horizontal.circle")
                        .font(.caption2)
                        .foregroundStyle(LoomTheme.Palette.accent)
                        .help("WebSocket · \(flow.webSocketMessages?.count ?? 0) messages")
                }
                Spacer(minLength: 0)
            }

        case .time:
            Text(flow.durationMS.map { "\($0)ms" } ?? "—")
                .font(.callout.monospacedDigit())
                .foregroundStyle(LoomTheme.durationStyle(ms: flow.durationMS))
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }
}

/// An `NSTableCellView` that draws a SwiftUI body, reused across rows.
///
/// Recycled like any other cell view, so the number of hosting views alive is the
/// viewport's, not the capture's — which is the property the whole port is for.
///
/// **Typed on `CellContent`, not `AnyView`.** Type erasure is the obvious way to hold
/// "some view" in a stored property and it costs exactly what this class exists to save:
/// `AnyView` is opaque to SwiftUI's structural diffing, so assigning a new one replaces
/// the view identity wholesale and re-creates the subtree instead of updating the text
/// in place. One concrete type means setting `rootView` on a row whose status changed is
/// a value update — which is the fast path, since an exchange upserts several times.
private final class HostingCell: NSTableCellView {
    private let hosting: NSHostingView<CellContent>

    init(identifier: NSUserInterfaceItemIdentifier, content: CellContent) {
        hosting = NSHostingView(rootView: content)
        super.init(frame: .zero)
        self.identifier = identifier
        // The cell's own sizing is the table's business, not the content's: an
        // unconstrained hosting view will happily ask for the width its text wants and
        // drag the column with it.
        hosting.translatesAutoresizingMaskIntoConstraints = false
        // A cell four points inside a table row has no safe area to respect, and opting
        // out of the tracking is worth a line here: every scroll frame moves the clip
        // view's bounds, AppKit walks its KVO dependents, and each hosting view answers
        // `invalidateSafeAreaInsets()` → a SwiftUI layout invalidation. At ~264 realized
        // cells (33 rows × 8 columns) that fan-out was the bulk of a glide frame in a
        // sample of the tail-follow.
        hosting.safeAreaRegions = []
        addSubview(hosting)
        let inset = RequestTable.Column(rawValue: identifier.rawValue)?.cellInset ?? 4
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset),
            hosting.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset),
            hosting.topAnchor.constraint(equalTo: topAnchor),
            hosting.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Assigning `rootView` runs a SwiftUI update transaction whether or not the value
    /// moved, so the guard is not a micro-optimisation: the viewport is refreshed after
    /// every capture batch, and at ~33 rows × 8 columns that is 264 update passes ten
    /// times a second for rows that mostly did not change. Measured, it was the single
    /// largest cost in the update.
    func host(_ content: CellContent) {
        guard content != hosting.rootView else { return }
        hosting.rootView = content
    }
}

/// An `NSScrollView` that reports its layout passes.
///
/// One job: the initial tail scroll needs a moment when the view has a size, and there
/// isn't one in `NSViewRepresentable`'s vocabulary. `updateNSView` runs when the data
/// changes, which under live capture is *before* the first layout — scrolling to the
/// bottom there scrolls to 0, because that is where the bottom of a zero-height document
/// is. `layout()` is the callback AppKit already has for "this view now has geometry".
final class RequestScrollView: NSScrollView {
    var onLayout: (() -> Void)?

    /// The axis a scroll gesture committed to on its first frame, held for the gesture.
    ///
    /// A trackpad reports diagonal deltas, so without this the clip view moves x and y at
    /// once and the list drifts sideways while someone is scrolling down. The lock is taken
    /// at `.began` and reused for the rest of that gesture including its momentum frames
    /// (which carry a `momentumPhase`, not another `.began`); the next `.began` overwrites
    /// it, so it is never explicitly cleared. A legacy notched wheel sends no phase at all,
    /// so it is locked per event instead — each notch is its own decision.
    private enum ScrollAxis { case vertical, horizontal }
    private var lockedAxis: ScrollAxis?

    override func scrollWheel(with event: NSEvent) {
        if event.phase.contains(.began) {
            lockedAxis = axis(of: event)
        } else if event.phase.isEmpty && event.momentumPhase.isEmpty {
            // Legacy wheel / no-phase device: decide this event on its own.
            lockedAxis = axis(of: event)
        }

        guard let lockedAxis, let cg = event.cgEvent?.copy(),
              let clamped = NSEvent(cgEvent: zeroingOffAxis(lockedAxis, of: cg)) else {
            super.scrollWheel(with: event)
            return
        }
        super.scrollWheel(with: clamped)
    }

    private func axis(of event: NSEvent) -> ScrollAxis {
        abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) ? .horizontal : .vertical
    }

    /// Zeros the CGEvent's delta fields on the axis that isn't locked. Axis1 is vertical,
    /// Axis2 horizontal; all three delta representations must be cleared or AppKit reads the
    /// one that survived.
    private func zeroingOffAxis(_ axis: ScrollAxis, of cg: CGEvent) -> CGEvent {
        let offAxisFields: [CGEventField] = axis == .vertical
            ? [.scrollWheelEventDeltaAxis2, .scrollWheelEventPointDeltaAxis2, .scrollWheelEventFixedPtDeltaAxis2]
            : [.scrollWheelEventDeltaAxis1, .scrollWheelEventPointDeltaAxis1, .scrollWheelEventFixedPtDeltaAxis1]
        for field in offAxisFields { cg.setDoubleValueField(field, value: 0) }
        return cg
    }

    override func layout() {
        super.layout()
        onLayout?()
    }
}
