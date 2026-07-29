import AppKit
import LoomSharedModels
import SwiftUI

/// Resolves a source app's icon from its `.app` bundle path via NSWorkspace
/// (synchronous and system-cached, so no async needed). Bundle-less origins
/// (CLI tools, daemons) have no icon and fall back to a generic symbol.
@MainActor
enum AppIconLoader {
    /// Bounded, because the project's rule is that every in-memory collection has
    /// an explicit cap and this was one of two that didn't: a plain dictionary
    /// keyed by bundle path grows one decoded `NSImage` per distinct app for the
    /// life of the process, and Loom is meant to sit in the menu bar for days.
    ///
    /// `NSCache` rather than a hand-rolled LRU: it evicts under memory pressure,
    /// it's the idiomatic AppKit answer for a string-keyed image cache, and a miss
    /// here costs one `NSWorkspace` call that is itself system-cached.
    static let cache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 256 // distinct apps seen in one session, generously
        return cache
    }()

    static func icon(for app: SourceApp) -> NSImage? {
        guard let path = app.bundlePath else { return nil }
        if let cached = cache.object(forKey: path as NSString) { return cached }
        let icon = NSWorkspace.shared.icon(forFile: path)
        icon.size = NSSize(width: 16, height: 16)
        cache.setObject(icon, forKey: path as NSString)
        return icon
    }
}

/// A source app's icon, with sensible fallbacks: a terminal glyph for CLI/daemon
/// origins (no bundle) and a question mark when the origin couldn't be resolved.
struct AppIconView: View {
    let app: SourceApp?

    var body: some View {
        if let app, let icon = AppIconLoader.icon(for: app) {
            Image(nsImage: icon)
                .resizable()
                .frame(width: 16, height: 16)
        } else {
            Image(systemName: app == nil ? "questionmark.app.dashed" : "terminal")
                .foregroundStyle(.secondary)
        }
    }
}
