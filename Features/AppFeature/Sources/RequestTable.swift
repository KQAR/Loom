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
/// That is the whole reason for this file: the window can hold a page instead of the
/// capture.
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
    let rows: [Flow]
    /// The whole capture, for the `#` column's 1-based position.
    ///
    /// The array itself rather than a precomputed `id → ordinal` dictionary: that
    /// dictionary was rebuilt on every capture batch, which is an allocation and a hash
    /// per retained flow ten times a second — measured at 20 000 rows, a meaningful
    /// share of the whole update. `IdentifiedArray.index(id:)` is O(1), so looking it up
    /// per *visible* cell costs the viewport instead of the capture. Passing the array
    /// is free (COW), and it is a value here, so no cell observes the store.
    let capture: IdentifiedArrayOf<Flow>
    @Binding var selection: Flow.ID?
    @Binding var followTail: Bool
    /// Row actions, as closures rather than a store reference: this view is about
    /// drawing rows, and handing it the store would let a cell reach anything.
    let onReplay: (Flow.ID) -> Void
    let onCopyCurl: (Flow.ID) -> Void
    let onAddRule: (Flow.ID, RuleTemplate) -> Void

    /// Fixed, not automatic: `usesAutomaticRowHeights` measures every row it draws, and
    /// every row here is one line of text by construction.
    static let rowHeight: CGFloat = 24

    func makeCoordinator() -> Coordinator {
        Coordinator(selection: $selection, followTail: $followTail,
                    onReplay: onReplay, onCopyCurl: onCopyCurl, onAddRule: onAddRule)
    }

    func makeNSView(context: Context) -> NSScrollView {
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

        for spec in Column.allCases {
            let column = NSTableColumn(identifier: spec.identifier)
            column.title = spec.title
            column.minWidth = spec.minWidth
            column.width = spec.idealWidth
            column.maxWidth = spec.maxWidth
            column.resizingMask = spec.maxWidth > spec.minWidth ? .userResizingMask : []
            table.addTableColumn(column)
        }

        let scrollView = NSScrollView()
        scrollView.documentView = table
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        context.coordinator.attach(scrollView: scrollView, table: table)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.update(rows: rows, capture: capture, selection: selection)
    }

    static func dismantleNSView(_ scrollView: NSScrollView, coordinator: Coordinator) {
        coordinator.detach()
    }

    // MARK: Columns

    /// The column set, as data rather than eight near-identical construction sites.
    /// Widths carried over verbatim from the SwiftUI `Table` this replaces, including
    /// the reasoning attached to two of them.
    enum Column: String, CaseIterable {
        case status, ordinal, app, proto, method, host, path, time

        var identifier: NSUserInterfaceItemIdentifier { .init(rawValue) }

        var title: String {
            switch self {
            case .status: ""
            case .ordinal: "#"
            case .app: "App"
            case .proto: "Protocol"
            case .method: "Method"
            case .host: "Host"
            case .path: "Path"
            case .time: "Time"
            }
        }

        var minWidth: CGFloat {
            switch self {
            case .status: 28
            case .ordinal: 30
            case .app: 36
            // Sized to the widest token this column can hold — `HTTPS`, 5 mono glyphs —
            // not to the header word, which is the only thing here that wants more room.
            case .proto: 46
            case .method: 52
            case .host: 110
            case .path: 160
            case .time: 56
            }
        }

        var idealWidth: CGFloat {
            switch self {
            case .status: 28
            case .ordinal: 38
            case .app: 36
            case .proto: 52
            case .method: 62
            case .host: 180
            case .path: 320
            case .time: 70
            }
        }

        var maxWidth: CGFloat {
            switch self {
            // Sized for five digits, not seven: the ring caps at 2000 and the persisted
            // store an order of magnitude above, so five is headroom already — and every
            // point it took came off Path, the one column never wide enough.
            case .status: 28
            case .ordinal: 56
            case .app: 36
            case .proto: 64
            case .method: 90
            case .host: 280
            case .path: 10_000
            case .time: 100
            }
        }
    }

    // MARK: Coordinator

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
        @Binding private var selection: Flow.ID?
        @Binding private var followTail: Bool
        private let onReplay: (Flow.ID) -> Void
        private let onCopyCurl: (Flow.ID) -> Void
        private let onAddRule: (Flow.ID, RuleTemplate) -> Void

        private weak var table: NSTableView?
        private weak var scrollView: NSScrollView?
        private var rows: [Flow] = []
        private var capture: IdentifiedArrayOf<Flow> = []
        /// Guards the selection write-back: `selectRowIndexes` fires the delegate, and
        /// echoing that back into the binding turns a programmatic sync into a user
        /// selection.
        private var applyingSelection = false

        init(
            selection: Binding<Flow.ID?>,
            followTail: Binding<Bool>,
            onReplay: @escaping (Flow.ID) -> Void,
            onCopyCurl: @escaping (Flow.ID) -> Void,
            onAddRule: @escaping (Flow.ID, RuleTemplate) -> Void
        ) {
            _selection = selection
            _followTail = followTail
            self.onReplay = onReplay
            self.onCopyCurl = onCopyCurl
            self.onAddRule = onAddRule
        }

        func attach(scrollView: NSScrollView, table: NSTableView) {
            self.scrollView = scrollView
            self.table = table
            let nc = NotificationCenter.default
            nc.addObserver(self, selector: #selector(userWillScroll),
                           name: NSScrollView.willStartLiveScrollNotification, object: scrollView)
            nc.addObserver(self, selector: #selector(userScrolling),
                           name: NSScrollView.didLiveScrollNotification, object: scrollView)
            nc.addObserver(self, selector: #selector(userScrolling),
                           name: NSScrollView.didEndLiveScrollNotification, object: scrollView)
            // Every viewport move, whoever caused it — a gesture, its momentum, a scroller
            // drag, a keyboard scroll. These only keep `followTail` reporting the truth to
            // the rest of the window; the decision to follow is not taken from them (see
            // `update`), because a bounds change cannot say who moved the viewport.
            let clipView = scrollView.contentView
            clipView.postsBoundsChangedNotifications = true
            nc.addObserver(self, selector: #selector(userScrolling),
                           name: NSView.boundsDidChangeNotification, object: clipView)
        }

        func detach() {
            stopGliding()
            NotificationCenter.default.removeObserver(self)
        }

        // MARK: Data

        func update(rows newRows: [Flow], capture newCapture: IdentifiedArrayOf<Flow>, selection newSelection: Flow.ID?) {
            let previous = rows
            rows = newRows
            capture = newCapture
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
            let wasAtBottom = isAtBottom() || displayLink != nil
            isApplyingUpdate = true
            defer { isApplyingUpdate = false }
            let diff = RowDiff(from: previous, to: newRows)
            apply(diff, in: table)
            applySelection(newSelection, in: table)
            // On the *diff*, not on a row-count change: once the window is at its cap the
            // head is trimmed by exactly what the tail gained, so the count is constant
            // while the list keeps moving — and a count gate silently stops following at
            // the one point where there is the most to follow.
            if wasAtBottom, diff != .none { scrollToBottom() }
            if followTail != wasAtBottom { followTail = wasAtBottom }
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
            refreshVisibleRows(in: table)
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

        private func applySelection(_ id: Flow.ID?, in table: NSTableView) {
            let target = id.flatMap { id in rows.firstIndex { $0.id == id } }
            let current = table.selectedRow
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
            stopGliding()
        }

        /// Keeps `followTail` reporting where the viewport actually is. It is a readout,
        /// not a latch: nothing decides anything from it here (`update` measures for
        /// itself), so there is no state to get stuck armed.
        @objc private func userScrolling() {
            guard !isApplyingUpdate, !isGliding else { return }
            let atBottom = isAtBottom()
            if followTail != atBottom { followTail = atBottom }
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
            let clipView = scrollView.contentView
            let remaining = maximumOffsetY - clipView.bounds.origin.y
            guard remaining > 0 else { return }
            guard remaining <= Self.maximumGlideDistance * clipView.bounds.height else {
                setOffsetY(maximumOffsetY)
                stopGliding()
                return
            }
            startGliding()
        }

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

        private var clickedFlow: Flow? {
            guard let table, rows.indices.contains(table.clickedRow) else { return nil }
            return rows[table.clickedRow]
        }

        func menuNeedsUpdate(_ menu: NSMenu) {
            menu.removeAllItems()
            guard let flow = clickedFlow else { return }
            let id = flow.id
            let host = MainView.host(flow.request.url)

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
            let rulesItem = NSMenuItem(title: "Add Rule", action: nil, keyEquivalent: "")
            rulesItem.submenu = rules
            menu.addItem(rulesItem)
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
/// Not a general diff, deliberately. A general LCS over 2 000 rows on every capture
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
    }

    var body: some View {
        switch column {
        case .status:
            StatusDot(flow: flow).frame(maxWidth: .infinity, alignment: .center)

        case .ordinal:
            Text("\(ordinal)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .trailing)

        case .app:
            AppIconView(app: flow.sourceApp)
                .help(flow.sourceApp?.name ?? "Unknown app")

        case .proto:
            Text(MainView.protocolLabel(flow))
                .font(.callout.monospaced())
                .foregroundStyle(.secondary)
                // The upstream version is the honest place to state it: it describes
                // Loom's own hop, not the client's (see `protocolLabel`).
                .help(flow.response?.httpVersion.map { "Upstream: \($0)" } ?? "")
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
        addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            hosting.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
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
