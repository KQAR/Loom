import AppKit
import ObjectiveC
import SwiftUI

/// Callbacks for a SwiftUI `Text` whose capture must survive a re-render.
@MainActor
final class WireTextHost: NSObject {
    var displayed = ""
    var hasOverride = false
    var onDecode: (String) -> Void = { _ in }
    var onShowOriginal: () -> Void = {}
}

/// Tags the SwiftUI-installed `NSTextView` without participating in hit-testing.
struct WireTextHostOverlay: NSViewRepresentable {
    var displayed: String
    var hasOverride: Bool
    var onDecode: (String) -> Void
    var onShowOriginal: () -> Void

    func makeNSView(context: Context) -> Sentinel {
        WireTextSystemMenu.install()
        let view = Sentinel()
        view.apply(self)
        return view
    }

    func updateNSView(_ view: Sentinel, context: Context) {
        view.apply(self)
    }

    final class Sentinel: NSView {
        let host = WireTextHost()

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window != nil {
                WireTextSentinels.views.add(self)
            } else {
                WireTextSentinels.views.remove(self)
            }
            coveringTextView()?.wireHost = host
        }

        override func layout() {
            super.layout()
            coveringTextView()?.wireHost = host
        }

        func apply(_ overlay: WireTextHostOverlay) {
            host.displayed = overlay.displayed
            host.hasOverride = overlay.hasOverride
            host.onDecode = overlay.onDecode
            host.onShowOriginal = overlay.onShowOriginal
            coveringTextView()?.wireHost = host
        }

        func coveringTextView() -> NSTextView? {
            let cover = convert(bounds, to: nil)
            guard cover.width > 1, cover.height > 1 else { return nil }
            var best: (CGFloat, NSTextView)?
            var node: NSView? = superview
            while let current = node {
                for textView in textViews(in: current) {
                    let score = Self.overlapScore(cover: cover, frame: textView.convert(textView.bounds, to: nil))
                    if score > (best?.0 ?? 0) {
                        best = (score, textView)
                    }
                }
                if let best, best.0 > 0.5 { return best.1 }
                node = current.superview
            }
            return (best?.0 ?? 0) > 0.5 ? best?.1 : nil
        }

        /// Both the overlay and the text view must mostly cover each other —
        /// a full-pane overlay intersecting a small cell must not steal it.
        private static func overlapScore(cover: CGRect, frame: CGRect) -> CGFloat {
            let overlap = cover.intersection(frame)
            let area = overlap.width * overlap.height
            guard area > 1 else { return 0 }
            let coverRatio = area / max(cover.width * cover.height, 1)
            let frameRatio = area / max(frame.width * frame.height, 1)
            return min(coverRatio, frameRatio)
        }

        private func textViews(in view: NSView) -> [NSTextView] {
            if let textView = view as? NSTextView { return [textView] }
            return view.subviews.flatMap(textViews(in:))
        }
    }
}

@MainActor
enum WireTextSentinels {
    static let views: NSHashTable<WireTextHostOverlay.Sentinel> = .weakObjects()

    /// The smallest overlay that contains this text view's centre. The menu-item
    /// click must not be used as the probe — that point sits in the menu, which
    /// often overlaps a header cell below the URL.
    static func covering(_ textView: NSTextView) -> WireTextHost? {
        let frame = textView.convert(textView.bounds, to: nil)
        let probe = NSPoint(x: frame.midX, y: frame.midY)
        var best: (CGFloat, WireTextHost)?
        for sentinel in views.allObjects {
            let rect = sentinel.convert(sentinel.bounds, to: nil)
            guard rect.width > 1, rect.height > 1, rect.contains(probe) else { continue }
            let area = rect.width * rect.height
            if best == nil || area < best!.0 {
                best = (area, sentinel.host)
            }
        }
        return best?.1
    }
}

enum WireTextPasteboard {
    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

private enum WireAssociation {
    nonisolated(unsafe) static var host: UInt8 = 0
    nonisolated(unsafe) static var original: UInt8 = 0
}

extension NSTextView {
    @MainActor
    var wireHost: WireTextHost? {
        get { objc_getAssociatedObject(self, &WireAssociation.host) as? WireTextHost }
        set {
            objc_setAssociatedObject(self, &WireAssociation.host, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        }
    }

    @MainActor
    var wireOriginal: String? {
        get { objc_getAssociatedObject(self, &WireAssociation.original) as? String }
        set {
            objc_setAssociatedObject(self, &WireAssociation.original, newValue, .OBJC_ASSOCIATION_COPY_NONATOMIC)
        }
    }
}
