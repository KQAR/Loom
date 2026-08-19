import AppKit
import LoomSharedModels
import SwiftUI

/// Size guards for the detail panes. A flow's body can be up to
/// `StreamRelay.captureCap` (5 MB); handing that to the render path unbounded
/// beachballs the panel on open.
enum InspectorText {
    /// Byte size above which a raw/body pane switches from the line-numbered
    /// SwiftUI `Text` (which lays its whole string out synchronously on the
    /// main thread) to a viewport-lazy `NSTextView` (`CodeTextView`), which
    /// only lays out the visible region — so the full body renders without
    /// stalling the UI on open.
    static let plainTextThreshold = 100_000
    /// A GraphQL request body is never this large. Above it we skip the full
    /// JSON deserialize `GraphQLParser` does, so opening a big POST's detail
    /// doesn't hang while building the tab strip.
    static let graphQLBodyLimit = 512_000

    /// Hoisted formatter — a per-render `ByteCountFormatter` allocates, and both
    /// callers sit on paths that re-render while a request is still streaming.
    /// `@MainActor` rather than `nonisolated(unsafe)`: `ByteCountFormatter` is not
    /// `Sendable`, and both callers are view bodies, so the isolation is a
    /// statement of where it is already used rather than a constraint added.
    @MainActor private static let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .binary
        return formatter
    }()

    /// One spelling of a size across the inspector — the summary's rows and the
    /// body pane's truncation strip quote the same numbers at each other.
    @MainActor static func byteCount(_ bytes: Int) -> String {
        byteFormatter.string(fromByteCount: Int64(bytes))
    }

    /// In-pane find wash. The system find yellow at full strength buries the
    /// ink; these keep the hue and drop the opacity so a hit is a mark, not a
    /// highlighter stroke.
    enum FindWash {
        static let otherOpacity: CGFloat = 0.15
        static let currentOpacity: CGFloat = 0.25

        static var other: Color { Color(nsColor: .findHighlightColor).opacity(otherOpacity) }
        static var current: Color { Color(nsColor: .findHighlightColor).opacity(currentOpacity) }

        static var otherNS: NSColor { NSColor.findHighlightColor.withAlphaComponent(otherOpacity) }
        static var currentNS: NSColor { NSColor.findHighlightColor.withAlphaComponent(currentOpacity) }
    }
}
