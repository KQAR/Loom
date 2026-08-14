import Foundation
import NIOCore
import NIOHTTP1
import LoomSharedModels

enum HTTPUtil {
    /// Headers that describe the hop, not the message — must not be forwarded.
    static let hopByHop: Set<String> = [
        "connection", "proxy-connection", "keep-alive", "proxy-authenticate",
        "proxy-authorization", "te", "trailer", "transfer-encoding", "upgrade",
    ]

    static func isHopByHop(_ name: String) -> Bool {
        hopByHop.contains(name.lowercased())
    }

    /// How a request head's version is spelled on a captured flow — `HTTP/1.1`,
    /// `HTTP/1.0`. **Not** usable for an intercepted h2 request: the h2↔h1 codec
    /// hands the decrypted request over as an HTTP/1.1 head, so this would report
    /// the shape the codec built rather than what the client negotiated. That path
    /// passes the ALPN result down explicitly instead (`MITMPipeline`).
    static func clientProtocol(_ version: HTTPVersion) -> String {
        "HTTP/\(version.major).\(version.minor)"
    }

    static func headerPairs(_ headers: HTTPHeaders) -> [HeaderPair] {
        headers.map { HeaderPair(name: $0.name, value: $0.value) }
    }

    /// The inverse, preserving order and repeats — a trailer section is an ordered
    /// list on the wire exactly as a header section is.
    static func httpHeaders(_ pairs: [HeaderPair]) -> HTTPHeaders {
        var headers = HTTPHeaders()
        for pair in pairs { headers.add(name: pair.name, value: pair.value) }
        return headers
    }

    /// Drop the headers that lie once the upstream body has been decoded for us:
    /// `Content-Encoding` (the bytes are already decompressed) and `Content-Length`
    /// (no longer matches; the response writer recomputes it). Keeping either makes
    /// the client try to re-decode plaintext and fail with -1015.
    ///
    /// Only applied when the response actually *was* encoded. A response with no
    /// `Content-Encoding` reaches us byte-for-byte, so its `Content-Length` is the
    /// truth — stripping it unconditionally cost fidelity in two visible ways: the
    /// captured flow (Inspector / HAR / `get_flow_detail`) lost a header the origin
    /// really sent, and `writeResponseHead(chunked: false)` — the bodyless path,
    /// which documents that it preserves the upstream length — had nothing left to
    /// preserve, so `curl -I` through Loom lost `Content-Length` entirely
    /// (RFC 9110 §9.3.2: a HEAD should report the length a GET would).
    static func sanitizeDecodedResponseHeaders(_ headers: [HeaderPair]) -> [HeaderPair] {
        let wasEncoded = headers.contains {
            $0.name.lowercased() == "content-encoding"
                && !$0.value.trimmingCharacters(in: .whitespaces).isEmpty
                && $0.value.caseInsensitiveCompare("identity") != .orderedSame
        }
        guard wasEncoded else { return headers }
        return headers.filter {
            let lower = $0.name.lowercased()
            return lower != "content-encoding" && lower != "content-length"
        }
    }

    /// Join HTTP/2 `cookie` crumbs back into the single field HTTP/1.1 requires.
    ///
    /// RFC 9113 §8.2.3 lets an h2 client split `cookie` into one field per cookie
    /// (better HPACK compression — Chrome does it for every cookie), and says an
    /// intermediary converting to HTTP/1.1 **must** concatenate them with `"; "`.
    /// `HTTP2FramePayloadToHTTP1ServerCodec` does not do this, so without this call
    /// Loom forwarded N separate `Cookie:` lines upstream. RFC 6265 §5.4 allows
    /// exactly one, so an origin reads the first crumb and ignores the rest: a
    /// signed-in github.com came back logged out (its `user_session` crumb was not
    /// first) and signing in again failed 422, while the browser still held every
    /// cookie. Applied to the intercepted request head, i.e. before capture — and
    /// that is the **canonical** form of the message, not merely what one leg needed:
    /// §8.2.3 requires the concatenation before the fields reach "an HTTP/1.1
    /// connection, **or a generic HTTP server application**", so the origin's
    /// application sees one field however the request was framed. The crumb split is
    /// below the semantic layer, like a body's DATA-frame boundaries — which Loom
    /// does not record either. See `splitCookieCrumbs` for the encoder that puts it
    /// back on an h2 leg.
    static func coalesceCookieCrumbs(_ headers: HTTPHeaders) -> HTTPHeaders {
        guard headers.filter({ $0.name.lowercased() == "cookie" }).count > 1 else { return headers }
        let joined = headers
            .filter { $0.name.lowercased() == "cookie" }
            .map { $0.value.trimmingCharacters(in: CharacterSet(charactersIn: "; ")) }
            .filter { !$0.isEmpty }
            .joined(separator: "; ")
        var out = HTTPHeaders()
        var emitted = false
        for header in headers {
            guard header.name.lowercased() == "cookie" else {
                out.add(name: header.name, value: header.value)
                continue
            }
            // Keep the crumbs' original position (first one wins) so header order
            // is otherwise as the client wrote it.
            if !emitted {
                emitted = true
                out.add(name: header.name, value: joined)
            }
        }
        return out
    }

    /// The inverse, applied when a request goes out over **HTTP/2**: one field per
    /// cookie-pair, which is the encoding RFC 9113 §8.2.3 exists to permit.
    ///
    /// This is an encoder, not an edit. The model keeps the canonical single field
    /// (see `coalesceCookieCrumbs`) and each leg frames it the way its protocol
    /// wants — h1 as one line because RFC 6265 §5.4 allows exactly one, h2 as crumbs
    /// because HPACK indexes fields whole.
    ///
    /// **What it buys is compression, and the accounting is the argument.** The HPACK
    /// dynamic table defaults to 4096 bytes and charges each field
    /// `name + value + 32`. A site with kilobytes of cookies produces a merged field
    /// that cannot fit the table at all, so it is re-sent as a literal on every
    /// single request; split, each pair fits, is indexed once, and costs about a byte
    /// thereafter. (Reasoned from the table size and the field-cost rule, not
    /// measured.) `SETTINGS_MAX_HEADER_LIST_SIZE` moves the other way — merging is
    /// *smaller* by the 32-byte-per-field overhead — so that limit is not the concern
    /// here.
    ///
    /// Two honest limits. The client's original grouping is gone by the time this
    /// runs, so this is a **reconstruction** per cookie-pair rather than a restoration
    /// — which happens to be what browsers send and what indexes best. And a value
    /// that cannot be split cleanly (no `; ` in it) simply stays one field, because
    /// producing a wrong split is worse than producing none.
    static func splitCookieCrumbs(_ headers: HTTPHeaders) -> HTTPHeaders {
        guard headers.contains(where: { $0.name.lowercased() == "cookie" }) else { return headers }
        var out = HTTPHeaders()
        for header in headers {
            guard header.name.lowercased() == "cookie" else {
                out.add(name: header.name, value: header.value)
                continue
            }
            let crumbs = header.value
                .split(separator: ";")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            // A single crumb (or a value that split into none) is written back
            // unchanged rather than reconstructed — same bytes, no cleverness.
            guard crumbs.count > 1 else {
                out.add(name: header.name, value: header.value)
                continue
            }
            for crumb in crumbs { out.add(name: header.name, value: crumb) }
        }
        return out
    }

    /// Write a complete HTTP/1.1 response down a channel and optionally close it.
    /// Shared by the plain-HTTP proxy path and the TLS-interception path so both
    /// frame responses identically (drop hop-by-hop + Content-Length, then set our
    /// own). Must be called on, or hop to, the channel's event loop.
    static func writeResponse(
        channel: Channel,
        status: Int,
        headers: [HeaderPair],
        body: Data,
        keepAlive: Bool
    ) {
        var responseHeaders = HTTPHeaders()
        for header in headers {
            let lower = header.name.lowercased()
            if isHopByHop(lower) || lower == "content-length" { continue }
            responseHeaders.add(name: header.name, value: header.value)
        }
        responseHeaders.replaceOrAdd(name: "Content-Length", value: String(body.count))
        responseHeaders.replaceOrAdd(name: "Connection", value: keepAlive ? "keep-alive" : "close")

        var writable = channel.allocator.buffer(capacity: body.count)
        writable.writeBytes(body)
        // Frozen for the event-loop closure below. `ByteBuffer` is a value type, so
        // this is a copy rather than a `var` the closure shares with this frame.
        let buffer = writable
        let head = HTTPResponseHead(version: .http1_1, status: .init(statusCode: status), headers: responseHeaders)

        channel.eventLoop.execute {
            channel.write(HTTPServerResponsePart.head(head), promise: nil)
            channel.write(HTTPServerResponsePart.body(.byteBuffer(buffer)), promise: nil)
            channel.writeAndFlush(HTTPServerResponsePart.end(nil)).whenComplete { _ in
                if !keepAlive {
                    channel.close(promise: nil)
                }
            }
        }
    }

    // MARK: - Streaming response writers (M4)

    /// A response to this request/status carries no message body (RFC 7230 §3.3):
    /// any response to HEAD, plus 1xx / 204 / 304. Such a response must NOT be
    /// framed `Transfer-Encoding: chunked` — emitting a `0\r\n\r\n` terminator
    /// after it corrupts framing on a keep-alive connection (e.g. `curl -I`).
    static func responseHasNoBody(requestMethod: String, status: Int) -> Bool {
        if requestMethod.caseInsensitiveCompare("HEAD") == .orderedSame { return true }
        switch status {
        case 100 ..< 200, 204, 304: return true
        default: return false
        }
    }

    /// Write just the response head. When `chunked` (the streaming default), frames
    /// as `Transfer-Encoding: chunked` so the body can stream without a known
    /// length (SSE / large downloads). When not chunked (bodyless responses), the
    /// upstream `Content-Length` is preserved and no chunk framing is added. Must
    /// hop to the event loop.
    static func writeResponseHead(channel: Channel, status: Int, headers: [HeaderPair], keepAlive: Bool, chunked: Bool = true) {
        var responseHeaders = HTTPHeaders()
        for header in headers {
            let lower = header.name.lowercased()
            if isHopByHop(lower) || lower == "transfer-encoding" { continue }
            if chunked, lower == "content-length" { continue }
            responseHeaders.add(name: header.name, value: header.value)
        }
        if chunked {
            responseHeaders.replaceOrAdd(name: "Transfer-Encoding", value: "chunked")
        }
        responseHeaders.replaceOrAdd(name: "Connection", value: keepAlive ? "keep-alive" : "close")
        let head = HTTPResponseHead(version: .http1_1, status: .init(statusCode: status), headers: responseHeaders)
        channel.eventLoop.execute {
            channel.writeAndFlush(HTTPServerResponsePart.head(head)).whenFailure { error in
                // A response the client will now never receive. Silently dropping
                // this is how a proxy turns its own failure into "the server never
                // answered" — see `finishResponse` for the same on the terminal write.
                Log.proxy.error("""
                Writing the response head to the client failed; the client will see no \
                response: \(String(describing: error), privacy: .public)
                """)
            }
        }
    }

    /// Write one streamed body chunk (chunk-encoded by the response encoder).
    static func writeResponseChunk(channel: Channel, data: Data) {
        guard !data.isEmpty else { return }
        var writable = channel.allocator.buffer(capacity: data.count)
        writable.writeBytes(data)
        let buffer = writable // frozen for the closure, as in `writeResponse`
        channel.eventLoop.execute {
            channel.writeAndFlush(HTTPServerResponsePart.body(.byteBuffer(buffer))).whenFailure { error in
                Log.proxy.error("""
                Writing a response body chunk to the client failed; the response is \
                truncated from here: \(String(describing: error), privacy: .public)
                """)
            }
        }
    }

    /// Terminate a streamed response (sends the final chunk) and close if needed.
    ///
    /// `trailers` are written after the terminating chunk, which is where a chunked
    /// message carries them (RFC 9112 §7.1.2) and where gRPC puts `grpc-status`.
    /// Only meaningful on a chunked response — a bodyless one (`chunked: false` in
    /// `writeResponseHead`) has no place to put them, and NIO's encoder drops them
    /// there rather than corrupting the framing.
    static func finishResponse(channel: Channel, keepAlive: Bool, trailers: [HeaderPair]? = nil) {
        let section = trailers.map(httpHeaders)
        channel.eventLoop.execute {
            channel.writeAndFlush(HTTPServerResponsePart.end(section)).whenComplete { result in
                if case let .failure(error) = result {
                    Log.proxy.error("""
                    Terminating the response to the client failed; the client is left \
                    waiting on a message that will never end: \
                    \(String(describing: error), privacy: .public)
                    """)
                }
                if !keepAlive { channel.close(promise: nil) }
            }
        }
    }

}
