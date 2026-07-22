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

    static func headerPairs(from response: HTTPURLResponse) -> [HeaderPair] {
        response.allHeaderFields.compactMap { key, value in
            guard let name = key as? String else { return nil }
            return HeaderPair(name: name, value: String(describing: value))
        }
    }

    /// Drop headers that lie once URLSession has decoded the body for us:
    /// `Content-Encoding` (the bytes are already decompressed) and `Content-Length`
    /// (no longer matches; the response writer recomputes it). Keeping either makes
    /// the client try to re-decode plaintext and fail with -1015.
    static func sanitizeDecodedResponseHeaders(_ headers: [HeaderPair]) -> [HeaderPair] {
        headers.filter {
            let lower = $0.name.lowercased()
            return lower != "content-encoding" && lower != "content-length"
        }
    }

    /// Build a URLRequest from a captured request, skipping headers that
    /// URLSession must own itself (hop-by-hop, Content-Length, Host).
    static func urlRequest(
        method: String,
        url: URL,
        headers: [HeaderPair],
        body: Data?
    ) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        for header in headers {
            let lower = header.name.lowercased()
            if isHopByHop(lower) || lower == "content-length" || lower == "host" { continue }
            request.setValue(header.value, forHTTPHeaderField: header.name)
        }
        request.httpBody = body
        return request
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

    /// A shared session for forwarding and replay. Redirects are surfaced as-is
    /// so the debugger shows the real 3xx rather than the followed result.
    /// Upstream connections must be direct: with Loom set as the system proxy,
    /// honoring system proxy settings would route our own forwarding back into
    /// Loom — an infinite self-proxy loop (duplicate flows, cascading timeouts).
    static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.connectionProxyDictionary = [:]
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        return URLSession(configuration: config, delegate: NoRedirectDelegate(), delegateQueue: nil)
    }()
}

/// Prevents URLSession from transparently following redirects.
final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}
