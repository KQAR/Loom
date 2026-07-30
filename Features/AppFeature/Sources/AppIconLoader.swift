import AppKit
import LoomSharedModels
import SwiftUI

/// Resolves a source app's icon from its `.app` bundle path. Bundle-less origins
/// (CLI tools, daemons) have no icon and fall back to a generic symbol.
///
/// The lookup used to be synchronous inside the cell body, on the grounds that
/// `NSWorkspace` is itself system-cached. Measured, a cache miss cost **24 ms**
/// (`appIconLookup=5x/122.23ms` across five misses) — paid on the main thread inside
/// a row body, which is the one place a capture proxy cannot afford to read a disk.
/// Now a miss returns nil and schedules the load, so the row renders immediately with
/// the fallback glyph and refreshes when the icon lands.
///
/// `NSWorkspace.icon(forFile:)` still runs on the main actor: it is not documented
/// thread-safe, and a rare 24 ms hop is worth less than an undefined one. What
/// changed is *when* — after the current update pass instead of inside it.
@MainActor
@Observable
final class AppIconLoader {
    static let shared = AppIconLoader()

    /// bundle path → icon. A present-but-nil value means "resolved, no icon", so a
    /// bundle-less or unreadable app isn't retried on every render.
    ///
    /// A dictionary rather than the `NSCache` this used to be: `@Observable` tracks
    /// the read in `AppIconView.body`, and an `NSCache` mutation is invisible to it —
    /// the row would never refresh when the icon arrived. Same reasoning, and the same
    /// hand-rolled bound, as `FaviconLoader.icons`.
    private(set) var icons: [String: NSImage?] = [:]

    /// Insertion order, so the cap evicts the oldest path.
    private var insertionOrder: [String] = []
    /// Distinct apps seen in one session, generously. Internal so the bound is
    /// assertable from a test.
    let maxIcons = 256

    private var inFlight: Set<String> = []

    init() {}

    /// The icon if it's already resolved; nil while it isn't, having scheduled the
    /// load. Safe to call from a view body — it never touches the disk inline.
    func icon(for app: SourceApp) -> NSImage? {
        guard let path = app.bundlePath else { return nil }
        if let resolved = icons[path] { return resolved }
        ensure(path)
        return nil
    }

    /// Schedule a resolve for this bundle path. Idempotent.
    func ensure(_ path: String) {
        guard icons[path] == nil, !inFlight.contains(path) else { return }
        inFlight.insert(path)
        // A main-actor hop, not a background one: this yields to the current update
        // pass and runs after it, keeping `NSWorkspace` on the thread it expects.
        Task { @MainActor [weak self] in
            guard let self else { return }
            let icon = NSWorkspace.shared.icon(forFile: path)
            icon.size = NSSize(width: 16, height: 16)
            store(icon, for: path)
            inFlight.remove(path)
        }
    }

    /// Record an answer and evict the oldest once past the cap.
    func store(_ icon: NSImage?, for path: String) {
        if icons[path] == nil { insertionOrder.append(path) }
        icons[path] = icon
        while insertionOrder.count > maxIcons {
            let oldest = insertionOrder.removeFirst()
            icons.removeValue(forKey: oldest)
        }
    }
}

/// A source app's icon, with sensible fallbacks: a terminal glyph for CLI/daemon
/// origins (no bundle) and a question mark when the origin couldn't be resolved.
struct AppIconView: View {
    let app: SourceApp?
    /// A plain reference, not `@ObservedObject`: `@Observable` tracks the `icons` read
    /// in `body` directly, and the loader is a process-wide singleton whose lifetime
    /// must not be tied to any one row's.
    private let loader = AppIconLoader.shared

    var body: some View {
        if let app, let icon = loader.icon(for: app) {
            Image(nsImage: icon)
                .resizable()
                .frame(width: 16, height: 16)
        } else {
            Image(systemName: app == nil ? "questionmark.app.dashed" : "terminal")
                .foregroundStyle(.secondary)
        }
    }
}
