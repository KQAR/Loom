import Foundation
import NIOCore
import NIOHTTP1
import SharedModels

enum HTTPUtil {
    /// Headers that describe the hop, not the message — must not be forwarded.
    static let hopByHop: Set<String> = [
        "connection", "proxy-connection", "keep-alive", "proxy-authenticate",
        "proxy-authorization", "te", "trailer", "transfer-encoding", "upgrade",
    ]

    static func isHopByHop(_ name: String) -> Bool {
        hopByHop.contains(name.lowercased())
    }

    static func headerPairs(_ headers: HTTPHeaders) -> [HeaderPair] {
        headers.map { HeaderPair(name: $0.name, value: $0.value) }
    }

    /// Drop headers that lie once the upstream body has been decoded for us:
    /// `Content-Encoding` (the bytes are already decompressed) and `Content-Length`
    /// (no longer matches; the response writer recomputes it). Keeping either makes
    /// the client try to re-decode plaintext and fail with -1015.
    static func sanitizeDecodedResponseHeaders(_ headers: [HeaderPair]) -> [HeaderPair] {
        headers.filter {
            let lower = $0.name.lowercased()
            return lower != "content-encoding" && lower != "content-length"
        }
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

        var buffer = channel.allocator.buffer(capacity: body.count)
        buffer.writeBytes(body)
        let head = HTTPResponseHead(version: .http1_1, status: .init(statusCode: status), headers: responseHeaders)

        channel.eventLoop.execute {
            channel.write(NIOAny(HTTPServerResponsePart.head(head)), promise: nil)
            channel.write(NIOAny(HTTPServerResponsePart.body(.byteBuffer(buffer))), promise: nil)
            channel.writeAndFlush(NIOAny(HTTPServerResponsePart.end(nil))).whenComplete { _ in
                if !keepAlive {
                    channel.close(promise: nil)
                }
            }
        }
    }

    // MARK: - Streaming response writers (M4)

    /// Write just the response head, framed as chunked so the body can stream in
    /// pieces without knowing its total length up front (SSE / large downloads).
    /// Keep-alive is preserved via chunked framing. Must hop to the event loop.
    static func writeResponseHead(channel: Channel, status: Int, headers: [HeaderPair], keepAlive: Bool) {
        var responseHeaders = HTTPHeaders()
        for header in headers {
            let lower = header.name.lowercased()
            if isHopByHop(lower) || lower == "content-length" || lower == "transfer-encoding" { continue }
            responseHeaders.add(name: header.name, value: header.value)
        }
        responseHeaders.replaceOrAdd(name: "Transfer-Encoding", value: "chunked")
        responseHeaders.replaceOrAdd(name: "Connection", value: keepAlive ? "keep-alive" : "close")
        let head = HTTPResponseHead(version: .http1_1, status: .init(statusCode: status), headers: responseHeaders)
        channel.eventLoop.execute {
            channel.writeAndFlush(NIOAny(HTTPServerResponsePart.head(head)), promise: nil)
        }
    }

    /// Write one streamed body chunk (chunk-encoded by the response encoder).
    static func writeResponseChunk(channel: Channel, data: Data) {
        guard !data.isEmpty else { return }
        var buffer = channel.allocator.buffer(capacity: data.count)
        buffer.writeBytes(data)
        channel.eventLoop.execute {
            channel.writeAndFlush(NIOAny(HTTPServerResponsePart.body(.byteBuffer(buffer))), promise: nil)
        }
    }

    /// Terminate a streamed response (sends the final chunk) and close if needed.
    static func finishResponse(channel: Channel, keepAlive: Bool) {
        channel.eventLoop.execute {
            channel.writeAndFlush(NIOAny(HTTPServerResponsePart.end(nil))).whenComplete { _ in
                if !keepAlive { channel.close(promise: nil) }
            }
        }
    }

}
