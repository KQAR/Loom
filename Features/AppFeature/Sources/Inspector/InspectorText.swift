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
}
