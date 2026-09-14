import Foundation
import LoomSharedModels

/// How large a field section HTTP/2 will actually carry, and Loom's estimate of
/// what a given one costs.
///
/// **SwiftNIO's frame encoder writes no CONTINUATION frames** (RFC 9113 §6.10 —
/// NIOHTTP2 only *parses* them). `HTTP2FrameEncoder.encode` puts the whole HPACK
/// block in one HEADERS payload and throws `frameSizeError` past
/// `SETTINGS_MAX_FRAME_SIZE`, which `NIOHTTP2Handler` reports as
/// `NIOHTTP2Errors.UnableToSerializeFrame` **at connection level** — so every other
/// stream on that socket dies for one oversized message. There is no knob, and no
/// way to pre-split.
///
/// A real HTTP/2 peer is not subject to this, because a real peer sends
/// CONTINUATION. So without a guard the failure exists *only while Loom is in the
/// path*, which is the one class of bug a debugging proxy must not introduce. It
/// was reported on a request (an Android attestation header on top of a grown
/// cookie jar) and is reproduced with no Loom code in `Tools/h2-frame-size-repro`.
///
/// **One definition for both legs, deliberately.** The upstream leg answers it by
/// not offering `h2` (`NIOStreamingForwarder`); the client leg has no such lever —
/// the connection already exists — so it answers with a 502 that says why
/// (`StreamRelay`). Two copies of the arithmetic is how one leg's ceiling drifts
/// from the other's.
enum HTTP2HeaderBudget {
    /// The ceiling, in bytes of `estimatedBlockBytes`.
    ///
    /// 16 KB is `SETTINGS_MAX_FRAME_SIZE`'s initial value (RFC 9113 §6.5.2) and the
    /// floor any peer may advertise. A peer's *actual* value is deliberately not
    /// consulted: on the upstream leg the protocol has to be chosen before the
    /// connection exists, and on the client leg `NIOHTTP2Handler` does not expose
    /// the peer's settings — so both decide against the guaranteed minimum, and
    /// both are conservative in the same direction.
    static let maxFieldSectionBytes = 1 << 14

    /// An upper bound on the HPACK block these fields would encode to.
    ///
    /// Deliberately an upper bound: HPACK only ever shrinks a field (Huffman is used
    /// when it is shorter, an indexed field costs about a byte), so a bound computed
    /// from raw bytes can refuse a section that would have fitted. Guessing low is
    /// the direction that kills a connection. **The high direction is not free
    /// either**, which is why the coefficients are the smallest sound ones rather
    /// than round numbers: a needless downgrade coalesces `cookie` back into one
    /// line, and that line meets an origin front-end's own limit (nginx's
    /// `large_client_header_buffers` defaults to 8 KB — see ProxyCore/CLAUDE.md
    /// § "A proxy must not be stricter than the origin").
    ///
    /// - `+ 8` per field: HPACK's literal prefix, plus a length prefix for the name
    ///   and one of up to three bytes for a value below 16 KB.
    /// - `+ 4` per cookie crumb, not 8: an h2 request leg re-splits `cookie`
    ///   (RFC 9113 §8.2.3) and each crumb is a *separate* field, but its name is the
    ///   static table's index 32 — one byte, not seven.
    /// - The 128 covers the pseudo-header block and the fields the forwarder adds
    ///   (`Host`, `Accept-Encoding`, framing).
    ///
    /// - Parameters:
    ///   - requestTarget: what becomes `:path`. **Not optional in practice and the
    ///     reason this parameter exists**: the target is part of the HEADERS block
    ///     and is *not* one of `headers`, so a request whose bytes are in a 20 KB
    ///     query string (an OAuth PAR `request`, a `SAMLRequest`) read as tiny and
    ///     went out over h2 to die exactly the way this type exists to prevent.
    ///   - authority: what becomes `:authority`.
    static func estimatedBlockBytes(
        _ headers: [HeaderPair], requestTarget: String = "", authority: String = ""
    ) -> Int {
        var total = 128 + requestTarget.utf8.count + authority.utf8.count
        for header in headers {
            total += header.name.utf8.count + header.value.utf8.count + 8
            if header.name.caseInsensitiveCompare("cookie") == .orderedSame {
                total += 4 * header.value.utf8.count { $0 == UInt8(ascii: ";") }
            }
        }
        return total
    }

    /// Whether these fields can be put on an HTTP/2 leg at all.
    static func fitsOneFrame(
        _ headers: [HeaderPair], requestTarget: String = "", authority: String = ""
    ) -> Bool {
        estimatedBlockBytes(headers, requestTarget: requestTarget, authority: authority)
            <= maxFieldSectionBytes
    }
}
