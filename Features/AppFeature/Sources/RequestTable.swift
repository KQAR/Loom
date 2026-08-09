import AppKit
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
    /// Capture order for the `#` column: `flow id → 1-based position`. Passed in
    /// because it is a projection of the whole capture, which the table must not
    /// otherwise observe — a cell that reads the store's flow list makes every realized
    /// row depend on every capture batch.
    let ordinals: [Flow.ID: Int]
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
        context.coordinator.update(rows: rows, ordinals: ordinals, selection: selection)
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

    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
        @Binding private var selection: Flow.ID?
        @Binding private var followTail: Bool
        private let onReplay: (Flow.ID) -> Void
        private let onCopyCurl: (Flow.ID) -> Void
        private let onAddRule: (Flow.ID, RuleTemplate) -> Void

        private weak var table: NSTableView?
        private weak var scrollView: NSScrollView?
        private var rows: [Flow] = []
        private var ordinals: [Flow.ID: Int] = [:]
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
            // Track during the gesture AND its momentum so re-follow triggers the instant
            // the bottom is reached, not just when the finger lifts.
            nc.addObserver(self, selector: #selector(userScrolling),
                           name: NSScrollView.didLiveScrollNotification, object: scrollView)
            nc.addObserver(self, selector: #selector(userScrolling),
                           name: NSScrollView.didEndLiveScrollNotification, object: scrollView)
        }

        func detach() { NotificationCenter.default.removeObserver(self) }

        // MARK: Data

        func update(rows newRows: [Flow], ordinals newOrdinals: [Flow.ID: Int], selection newSelection: Flow.ID?) {
            let countChanged = newRows.count != rows.count
            let contentChanged = newRows != rows
            rows = newRows
            ordinals = newOrdinals
            guard let table else { return }
            if contentChanged { table.reloadData() }
            applySelection(newSelection, in: table)
            if followTail, countChanged { scrollToBottom() }
        }

        func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard let tableColumn, let column = Column(rawValue: tableColumn.identifier.rawValue),
                  rows.indices.contains(row)
            else { return nil }
            let flow = rows[row]
            let cell = tableView.makeView(withIdentifier: tableColumn.identifier, owner: self) as? HostingCell
                ?? HostingCell(identifier: tableColumn.identifier)
            cell.host(CellContent(column: column, flow: flow, ordinal: ordinals[flow.id] ?? row + 1))
            return cell
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
            // Both branches matter: a recycled row view keeps its predecessor's colour,
            // so the `else` is what stops the fill smearing onto healthy rows.
            rowView.backgroundColor = failed ? LoomTheme.rowFillError : .clear
            return rowView
        }

        private static let rowViewIdentifier = NSUserInterfaceItemIdentifier("loom.request.row")

        /// Selection drawn in **Loom's** accent, not the system's.
        ///
        /// The `Table` this replaces got there with `.tint(LoomTheme.Palette.accent)`,
        /// and DESIGN.md § Colors is why: selection is an interactive signal, and an
        /// untinted `NSTableView` fills the row with the hue the *user* set in System
        /// Settings — a colour sitting right next to Loom's accent-tinted method glyphs
        /// and toolbar toggles and disagreeing with them.
        ///
        /// Drawn at partial opacity rather than as a solid fill, which is the one
        /// deliberate difference from before: SwiftUI inverted a selected row's label
        /// colours for free, and these cells host their own SwiftUI trees that know
        /// nothing about the row's selection state. A solid accent would leave
        /// `.secondary` text sitting on it. A wash reads as selection and keeps every
        /// cell legible without either layer having to know about the other.
        final class RowView: NSTableRowView {
            /// Emphasized = this table has focus. The unfocused wash is weaker for the
            /// same reason AppKit's own is: an inactive selection should not compete
            /// with the active one in another pane.
            override func drawSelection(in dirtyRect: NSRect) {
                guard selectionHighlightStyle != .none else { return }
                let accent = NSColor(LoomTheme.Palette.accent)
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

        @objc private func userWillScroll() {
            if followTail { followTail = false } // the user took control
        }

        @objc private func userScrolling() {
            let atBottom = isAtBottom()
            if followTail != atBottom { followTail = atBottom }
        }

        private func isAtBottom() -> Bool {
            guard let table, table.numberOfRows > 0 else { return true }
            let visible = table.rows(in: table.visibleRect)
            return NSMaxRange(visible) >= table.numberOfRows
        }

        private func scrollToBottom() {
            guard let table, table.numberOfRows > 0 else { return }
            table.scrollRowToVisible(table.numberOfRows - 1)
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

/// One cell's SwiftUI content, chosen by column.
///
/// The cell bodies are unchanged from the `Table` this replaces — same views, fonts and
/// tints — because what moved down a layer is who owns the rows, not what a row looks
/// like. DESIGN.md governs this, and it should keep governing one idiom.
private struct CellContent: View {
    let column: RequestTable.Column
    let flow: Flow
    let ordinal: Int

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
private final class HostingCell: NSTableCellView {
    private let hosting = NSHostingView(rootView: AnyView(EmptyView()))

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
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

    func host(_ content: some View) {
        hosting.rootView = AnyView(content)
    }
}
