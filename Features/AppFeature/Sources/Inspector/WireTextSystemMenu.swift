import AppKit
import SwiftUI

/// Injects **URL Decode** / **Show Original** into the system `NSTextView`
/// context menu. Right-clicks are never stolen — native selection stays.
///
/// SwiftUI recreates its `NSTextView` when the string changes (decode), so the
/// new view is untagged. Hosts are looked up by geometry from the overlay that
/// still holds `hasOverride`, then the new view is re-tagged.
@MainActor
enum WireTextSystemMenu {
    private static var installed = false
    private static let observer = MenuObserver()

    static func install() {
        guard !installed else { return }
        installed = true
        NotificationCenter.default.addObserver(
            observer,
            selector: #selector(MenuObserver.menuDidBeginTracking(_:)),
            name: NSMenu.didBeginTrackingNotification,
            object: nil
        )
    }

    static func insert(into menu: NSMenu, textView: NSTextView) {
        guard let copyIndex = menu.items.firstIndex(where: { $0.action == #selector(NSText.copy(_:)) })
        else { return }
        menu.items
            .filter { $0.identifier == .loomURLDecode || $0.identifier == .loomShowOriginal }
            .forEach(menu.removeItem)
        let host = resolveHost(for: textView)
        let payload = payload(for: textView)
        let decode = NSMenuItem(
            title: "URL Decode",
            action: #selector(WireTextMenuAction.decode(_:)),
            keyEquivalent: ""
        )
        decode.identifier = .loomURLDecode
        decode.target = WireTextMenuAction.shared
        decode.representedObject = textView
        decode.isEnabled = payload.decodedDisplayed != nil
        menu.insertItem(decode, at: copyIndex + 1)
        if isShowingOverride(textView, host: host) {
            let original = NSMenuItem(
                title: "Show Original",
                action: #selector(WireTextMenuAction.showOriginal(_:)),
                keyEquivalent: ""
            )
            original.identifier = .loomShowOriginal
            original.target = WireTextMenuAction.shared
            original.representedObject = textView
            menu.insertItem(original, at: copyIndex + 2)
        }
    }

    static func payload(for textView: NSTextView) -> WireTextMenuPayload {
        let viewString = textView.string
        let range = textView.selectedRange
        let host = resolveHost(for: textView)
        let wholeView = NSRange(location: 0, length: (viewString as NSString).length)
        // Truncated URL bar: the view shows less than the capture. Only then
        // may we decode `host.displayed` instead of the view — and only when
        // the whole view is the selection. A partial selection always acts on
        // the bytes in *this* text view, never a neighbour's `displayed`.
        let displayed: String
        if let host,
           host.displayed != viewString,
           NSEqualRanges(range, wholeView) {
            displayed = host.displayed
        } else {
            displayed = viewString
        }
        return WireTextMenuPayload.resolve(
            displayed: displayed,
            viewString: viewString,
            selectedRange: range
        )
    }

    static func resolveHost(for textView: NSTextView) -> WireTextHost? {
        if let host = WireTextSentinels.covering(textView) {
            textView.wireHost = host
            return host
        }
        return textView.wireHost
    }

    static func isShowingOverride(_ textView: NSTextView, host: WireTextHost? = nil) -> Bool {
        (host ?? resolveHost(for: textView))?.hasOverride == true || textView.wireOriginal != nil
    }

    static func selectAll(_ textView: NSTextView) {
        let length = (textView.string as NSString).length
        textView.setSelectedRange(NSRange(location: 0, length: length))
        textView.window?.makeFirstResponder(textView)
    }
}

@MainActor
private final class MenuObserver: NSObject {
    @objc func menuDidBeginTracking(_ note: Notification) {
        guard let menu = note.object as? NSMenu else { return }
        guard menu.items.contains(where: { $0.action == #selector(NSText.copy(_:)) }) else { return }
        guard let textView = Self.textView() else { return }
        if WireTextSystemMenu.isShowingOverride(textView) {
            WireTextSystemMenu.selectAll(textView)
        }
        WireTextSystemMenu.insert(into: menu, textView: textView)
    }

    private static func textView() -> NSTextView? {
        if let event = NSApp.currentEvent, let window = event.window {
            var view = window.contentView?.hitTest(event.locationInWindow)
            while let current = view {
                if let textView = current as? NSTextView { return textView }
                view = current.superview
            }
        }
        return NSApp.keyWindow?.firstResponder as? NSTextView
    }
}

private extension NSUserInterfaceItemIdentifier {
    static let loomURLDecode = Self("com.loom.urlDecode")
    static let loomShowOriginal = Self("com.loom.showOriginal")
}

@MainActor
private final class WireTextMenuAction: NSObject {
    static let shared = WireTextMenuAction()

    @objc func decode(_ sender: NSMenuItem) {
        guard let textView = sender.representedObject as? NSTextView else { return }
        if let host = WireTextSystemMenu.resolveHost(for: textView),
           let decoded = WireTextSystemMenu.payload(for: textView).decodedDisplayed {
            host.onDecode(decoded)
            host.displayed = decoded
            host.hasOverride = true
            WireTextSystemMenu.selectAll(textView)
            return
        }
        let ns = textView.string as NSString
        let range = textView.selectedRange
        let target = range.length > 0 && NSMaxRange(range) <= ns.length
            ? range
            : NSRange(location: 0, length: ns.length)
        guard let decoded = PercentDecoding.decoded(ns.substring(with: target)) else { return }
        if textView.wireOriginal == nil { textView.wireOriginal = textView.string }
        textView.textStorage?.replaceCharacters(in: target, with: decoded)
        WireTextSystemMenu.selectAll(textView)
    }

    @objc func showOriginal(_ sender: NSMenuItem) {
        guard let textView = sender.representedObject as? NSTextView else { return }
        if let host = WireTextSystemMenu.resolveHost(for: textView) {
            host.onShowOriginal()
            host.hasOverride = false
            return
        }
        if let original = textView.wireOriginal {
            textView.string = original
            textView.wireOriginal = nil
            WireTextSystemMenu.selectAll(textView)
        }
    }

    @objc func validateMenuItem(_ item: NSMenuItem) -> Bool {
        guard let textView = item.representedObject as? NSTextView else { return false }
        switch item.identifier {
        case .loomURLDecode:
            return WireTextSystemMenu.payload(for: textView).decodedDisplayed != nil
        case .loomShowOriginal:
            return WireTextSystemMenu.isShowingOverride(textView)
        default:
            return true
        }
    }
}
