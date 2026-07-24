import AppKit
import LoomSharedModels
import SwiftUI

/// Resolves a source app's icon from its `.app` bundle path via NSWorkspace
/// (synchronous and system-cached, so no async needed). Bundle-less origins
/// (CLI tools, daemons) have no icon and fall back to a generic symbol.
@MainActor
enum AppIconLoader {
    private static var cache: [String: NSImage] = [:]

    static func icon(for app: SourceApp) -> NSImage? {
        guard let path = app.bundlePath else { return nil }
        if let cached = cache[path] { return cached }
        let icon = NSWorkspace.shared.icon(forFile: path)
        icon.size = NSSize(width: 16, height: 16)
        cache[path] = icon
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
