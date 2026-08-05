import Foundation
import LoomSharedModels

/// Which reverse-proxy endpoints the console's card draws, in what order, and how many
/// it leaves out.
///
/// Pulled out of the view so it can be tested: what makes this list worth drawing at
/// all is the *failed* case — an endpoint whose port didn't bind — and that is the one
/// nobody reproduces on demand while looking at a SwiftUI preview.
///
/// This is the **only** place endpoints are reported to the human. They used to also
/// appear as caption lines under the console header's address, next to the proxy and
/// SOCKS ports; that copy is gone. Endpoints are the one listener list whose other
/// writer is an agent, so two renderings meant two things to keep in step — and the
/// header was the rendering with no room for the local URL to copy, the upstream it
/// forwards to, or a way to remove it.
struct ReverseProxyList {
    /// At most this many endpoints are drawn before the rest collapse into a count. The
    /// console is a fixed-width popover and an agent can open as many endpoints as it
    /// likes; a card that grows without bound would push the footer off screen.
    static let visibleLimit = 6

    /// Endpoints to draw, and how many were left out (0 when none were).
    ///
    /// Not-listening endpoints sort **first**. If a truncation ever hides something it
    /// must not be the fault: an endpoint whose port didn't bind is experienced by its
    /// client as connection refused, i.e. as Loom being down, and that is the one entry
    /// worth its vertical space. Ties break oldest-first so the list doesn't reshuffle
    /// as endpoints come and go.
    static func rows(for endpoints: [ReverseProxyStatus]) -> (rows: [ReverseProxyStatus], hidden: Int) {
        guard !endpoints.isEmpty else { return ([], 0) }
        let ordered = endpoints.sorted { lhs, rhs in
            lhs.isListening == rhs.isListening
                ? lhs.endpoint.createdAt < rhs.endpoint.createdAt
                : !lhs.isListening
        }
        return (Array(ordered.prefix(visibleLimit)), max(0, ordered.count - visibleLimit))
    }

    /// The primary line for one endpoint: what a client is pointed at. `nil` boundPort
    /// means it isn't listening, and then the *requested* port is named — that is the
    /// number in a dev server's config, so it is the one the human recognizes.
    static func target(for status: ReverseProxyStatus) -> String {
        status.localURL ?? "port \(status.endpoint.requestedPort) — not listening"
    }

    /// One line that answers "where does this go, and is it working".
    ///
    /// A bind failure is stated in full rather than shortened: it is the case this list
    /// exists for, and the client experiences it as connection refused rather than as
    /// an error from Loom, so the reason has to be readable here.
    static func caption(for status: ReverseProxyStatus) -> String {
        if let error = status.error { return "Not listening — \(error)" }
        var parts = ["→ \(status.endpoint.upstream)"]
        if let label = status.endpoint.label, !label.isEmpty { parts.append(label) }
        if status.endpoint.keepHostHeader { parts.append("keeps Host header") }
        return parts.joined(separator: " · ")
    }
}
