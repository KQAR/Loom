import AppKit
import SwiftUI

/// Keeps the request table pinned to the newest row as it grows — the tail-follow
/// behavior of a log viewer — and steps out of the way the moment the user scrolls.
///
/// SwiftUI's `Table` is NSTableView-backed and `ScrollViewReader` doesn't reliably
/// drive it, so this bridges to AppKit: it locates the table's `NSScrollView`,
/// scrolls to the last row when `follow` is on and the row count changes, and
/// listens for **live-scroll** notifications (user gesture only — programmatic
/// scrolls don't fire them) to turn following off. Following turns back on when
/// the user scrolls back to the bottom.
struct RequestTableAutoScroll: NSViewRepresentable {
    /// Drives updates: a change re-runs `updateNSView`, where we scroll if following.
    let rowCount: Int
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
            if follow { context.coordinator.scrollToBottom() }
        }
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.detach()
    }

    final class Coordinator {
        @Binding var follow: Bool
        private weak var scrollView: NSScrollView?

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
