import Foundation
import LoomSharedModels

/// The reverse-proxy endpoints as caption lines under the console header's address.
///
/// They are *reported* here, **with** the address, because an endpoint is a listening
/// port on this machine — the same kind of fact as `127.0.0.1:9090` and the SOCKS
/// line, and a client is pointed at it the same way. They are *configured* in the
/// Reverse Proxies row below (`ReverseProxyCard`), which is an **action** row and not
/// a state row for the reason this block exists: there is no switch here to flip,
/// endpoints are added and removed one at a time, and the console's only switch stays
/// the proxy on/off in the header (§ DESIGN.md).
///
/// Derivation is pulled out of the view so it can be tested: what makes this worth
/// showing at all is the *failed* case, and that is the one a human never manages to
/// reproduce on demand while looking at a SwiftUI preview.
struct ReverseProxyHeaderLines {
    /// One endpoint, rendered.
    struct Line: Equatable, Identifiable {
        var id: UUID
        /// `:9200 → api.github.com`, or `:9200 ✕ api.github.com` when it isn't
        /// listening. The arrow reads as "forwards to"; the cross is the whole point
        /// of showing the line, so it must not look like a quieter arrow.
        var text: String
        /// Whether this endpoint is listening. Drives the colour; a not-listening
        /// endpoint is a fault, not a dimmed detail.
        var isListening: Bool
        /// Tooltip: the full upstream, plus the bind error when there is one.
        var help: String
    }

    /// At most this many endpoint lines are drawn before the rest collapse into a
    /// count. The console's scarcest resource is vertical space, and an agent can
    /// open as many endpoints as it likes.
    static let visibleLimit = 3

    /// Lines to draw, and how many endpoints were left out (0 when none were).
    ///
    /// Not-listening endpoints are ordered **first**. If a truncation ever hides
    /// something, it must not be the fault: an endpoint whose port didn't bind is
    /// experienced by its client as connection refused, i.e. as Loom being down, and
    /// that is the one line worth its space.
    static func lines(for endpoints: [ReverseProxyStatus]) -> (lines: [Line], hidden: Int) {
        guard !endpoints.isEmpty else { return ([], 0) }
        let ordered = endpoints.sorted { lhs, rhs in
            lhs.isListening == rhs.isListening
                ? lhs.endpoint.createdAt < rhs.endpoint.createdAt
                : !lhs.isListening
        }
        let shown = ordered.prefix(visibleLimit).map(line(for:))
        return (Array(shown), max(0, ordered.count - visibleLimit))
    }

    private static func line(for status: ReverseProxyStatus) -> Line {
        let host = URLHost.host(ofURLString: status.endpoint.upstream) ?? status.endpoint.upstream
        // The port the *client* connects to. Bound port when listening; otherwise the
        // one that was asked for, because that is what a dev server's config names and
        // therefore what the human has to recognize.
        let port = status.boundPort ?? status.endpoint.requestedPort
        let label = status.endpoint.label.map { " \($0)" } ?? ""
        var help = "Reverse proxy: requests to port \(port) are captured and forwarded to \(status.endpoint.upstream)."
        if let error = status.error {
            help = "Not listening — \(error). A client pointed at port \(port) gets connection refused."
        }
        return Line(
            id: status.endpoint.id,
            text: ":\(port) \(status.isListening ? "→" : "✕") \(host)\(label)",
            isListening: status.isListening,
            help: help
        )
    }
}
