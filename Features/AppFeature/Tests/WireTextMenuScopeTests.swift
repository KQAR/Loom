import AppKit
import Testing
@testable import AppFeature

/// What the **URL Decode** / **Show Original** hook is allowed to touch.
///
/// The hook is a process-wide `NSMenu.didBeginTracking` observer, so it sees
/// every menu in the app. Its only test used to be "does this menu carry a Copy
/// item", which the standard Edit menu does — so opening Edit with an inspector
/// text view as first responder inserted Loom's items into the app's **main
/// menu**, and selected that view's whole body on the way there.
///
/// The scope is deliberately two conditions and no more. A first attempt also
/// demanded a *tagged* text view, which reads sensible and turned the menu item
/// off everywhere: the view comes from a hit test and SwiftUI rebuilds its
/// `NSTextView` on every string change, so the one under the cursor is usually
/// untagged and gets re-found by geometry further in.
@Suite @MainActor struct WireTextMenuScopeTests {
    private func copyBearingMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        return menu
    }

    /// Shaped like `CodeTextView`'s: read-only, selectable, host attached.
    private func taggedTextView() -> NSTextView {
        let textView = untaggedTextView()
        textView.wireHost = WireTextHost()
        return textView
    }

    private func untaggedTextView() -> NSTextView {
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 40))
        textView.string = "https://example.com/%20path"
        textView.isEditable = false
        textView.isSelectable = true
        return textView
    }

    /// Shaped like the pane's find field: an `NSTextView` like any other.
    private func editableTextView() -> NSTextView {
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 140, height: 20))
        textView.string = "%20"
        textView.isEditable = true
        textView.wireHost = WireTextHost()
        return textView
    }

    @Test func aWireTextContextMenuIsAugmented() {
        let menu = copyBearingMenu()
        #expect(WireTextSystemMenu.shouldAugment(
            menu: menu, textView: taggedTextView(), mainMenu: NSMenu()
        ))
    }

    @Test func theMainMenuIsNeverAugmented() {
        let mainMenu = NSMenu()
        let edit = copyBearingMenu()
        let item = NSMenuItem()
        mainMenu.addItem(item)
        mainMenu.setSubmenu(edit, for: item)
        #expect(edit.supermenu === mainMenu)
        #expect(!WireTextSystemMenu.shouldAugment(
            menu: edit, textView: taggedTextView(), mainMenu: mainMenu
        ))
    }

    @Test func aNestedMainMenuSubmenuIsAlsoTheMainMenu() {
        let mainMenu = NSMenu()
        let edit = NSMenu()
        let find = copyBearingMenu()
        let editItem = NSMenuItem()
        mainMenu.addItem(editItem)
        mainMenu.setSubmenu(edit, for: editItem)
        let findItem = NSMenuItem()
        edit.addItem(findItem)
        edit.setSubmenu(find, for: findItem)
        #expect(WireTextSystemMenu.isDescendant(find, of: mainMenu))
        #expect(!WireTextSystemMenu.shouldAugment(
            menu: find, textView: taggedTextView(), mainMenu: mainMenu
        ))
    }

    @Test func anEditableTextViewIsNeverOfferedADecode() {
        // The pane's find field sits *over* the panes, and its field editor is
        // an `NSTextView` like everything else. Read-only is the discriminator:
        // every captured string Loom renders is read-only, and no field Loom
        // lets anyone type into is.
        #expect(!WireTextSystemMenu.shouldAugment(
            menu: copyBearingMenu(), textView: editableTextView(), mainMenu: NSMenu()
        ))
    }

    @Test func anUntaggedReadOnlyViewIsStillOffered() {
        // The narrowing that broke it: after a decode SwiftUI hands back a
        // fresh, untagged text view, and `insert`/`decode` resolve the host —
        // or fall back to the text storage — themselves.
        let menu = copyBearingMenu()
        WireTextSystemMenu.insert(into: menu, textView: untaggedTextView())
        #expect(menu.items.contains { $0.title == "URL Decode" })
    }

    @Test func aMenuWithNoCopyItemIsNotAContextMenu() {
        #expect(!WireTextSystemMenu.shouldAugment(
            menu: NSMenu(), textView: taggedTextView(), mainMenu: NSMenu()
        ))
    }

    @Test func insertRefusesAMenuItMayNotTouch() {
        // `insert` re-checks rather than trusting its caller, so the observer
        // and any future call site cannot disagree about the scope.
        let menu = copyBearingMenu()
        WireTextSystemMenu.insert(into: menu, textView: editableTextView())
        #expect(!menu.items.contains { $0.title == "URL Decode" })
    }

    @Test func insertAddsTheItemForWireText() {
        let menu = copyBearingMenu()
        WireTextSystemMenu.insert(into: menu, textView: taggedTextView())
        #expect(menu.items.contains { $0.title == "URL Decode" })
    }
}
