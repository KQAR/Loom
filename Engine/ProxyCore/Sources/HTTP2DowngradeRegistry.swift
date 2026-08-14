import Foundation
import Synchronization

/// Hosts whose client leg Loom has been forced to serve as HTTP/1.1, and why.
///
/// **The bug this works around is upstream and Loom cannot reach it.** SwiftNIO builds
/// its HPACK decoder with the library default `maxHeaderListSize` of 16 KB
/// (`HTTP2FrameParser`: `HPACKDecoder(allocator:)`, still true in 1.45.0) and only
/// raises it to the value Loom advertises when the peer **ACKs** Loom's SETTINGS. RFC
/// 9113 §3.4 explicitly lets a client send its first request without waiting for that
/// ACK, and OkHttp does. So a first request whose *decoded* header list exceeds 16 KB —
/// an app whose session cookies have grown, which is ordinary — is refused with
/// `MaxHeaderListSizeViolation`, which NIOHTTP2 reports as a connection-level
/// `COMPRESSION_ERROR`. HPACK is per-connection state, so the connection dies.
///
/// Measured, with a 60-line reproduction that uses no Loom code (`Tools/h2-hpack-repro`):
/// a 20 600-byte header list sent immediately gets `GOAWAY errorCode=0x9`; the same
/// list sent *after* ACKing the server's SETTINGS is answered normally; and the same
/// 22 KB `Cookie` over HTTP/1.1 through Loom answers 200. There is no knob —
/// `NIOHTTP2Handler.Configuration` exposes nothing for the decoder — so the only
/// lever Loom has is **not offering h2 to that host**.
///
/// Three rules.
///
/// **The trigger is narrow.** Only a codec error on a connection that has not yet
/// delivered a single frame, i.e. the first header block. A codec error later in a
/// connection's life is something else and must not silently change how the next
/// connection is negotiated.
///
/// **It is session-scoped and not persisted.** The condition depends on how large the
/// client's headers are *today* and on a library version; carrying it across launches
/// would keep an app on HTTP/1.1 long after the reason expired, with nothing to
/// explain why.
///
/// **A downgraded exchange says so.** `FlowTransport.clientProtocolDowngraded` marks
/// every flow captured over a forced h1 leg, because `CapturedRequest.httpVersion`
/// then reports HTTP/1.1 and that is true of what happened and false about what the
/// client would have done — a difference the operator is measuring against production.
final class HTTP2DowngradeRegistry: Sendable {
    /// Process-wide, like `TunneledHostLog`: the decision is read while building a TLS
    /// context deep in a channel initializer and written from a channel handler, with
    /// no engine reference in either.
    static let shared = HTTP2DowngradeRegistry()

    private let hosts = Mutex<Set<String>>([])

    init() {}

    /// Record that `host` must be served HTTP/1.1 from now on. Returns whether this
    /// changed anything, so the caller only invalidates a cached context once.
    @discardableResult
    func downgrade(host: String) -> Bool {
        hosts.withLock { $0.insert(host.lowercased()).inserted }
    }

    func isDowngraded(host: String) -> Bool {
        hosts.withLock { $0.contains(host.lowercased()) }
    }

    var downgradedHosts: [String] {
        hosts.withLock { $0.sorted() }
    }

    /// For tests, and for an embedder that restarts the engine in one process.
    func reset() {
        hosts.withLock { $0.removeAll() }
    }
}
