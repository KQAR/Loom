import Foundation
import SharedModels

/// The upstream leg of a proxied exchange, factored out so the plain-HTTP path,
/// the TLS-interception path, and replay all re-send through one place — and so
/// tests can inject a deterministic stub instead of hitting the network.
struct ForwardResult: Sendable {
    var statusCode: Int
    var headers: [HeaderPair]
    var body: Data
}

protocol UpstreamForwarding: Sendable {
    func forward(method: String, url: URL, headers: [HeaderPair], body: Data?) async throws -> ForwardResult
}

/// Live forwarder: re-issues the request with `URLSession` (M1 pragmatism —
/// swap for a streaming NIO client if transparency ever demands it). For the
/// intercept path this means Loom terminates the client's TLS and originates a
/// fresh, normally-validated TLS connection to the real server.
final class URLSessionForwarder: UpstreamForwarding {
    func forward(method: String, url: URL, headers: [HeaderPair], body: Data?) async throws -> ForwardResult {
        let request = HTTPUtil.urlRequest(method: method, url: url, headers: headers, body: body)
        let (data, response) = try await HTTPUtil.session.data(for: request)
        let http = response as? HTTPURLResponse
        // URLSession transparently decompresses the body (gzip/deflate/br), so the
        // bytes we hold are plaintext. Forwarding the origin's `Content-Encoding`
        // would tell the client to decode already-decoded data — Secure Transport
        // then fails the whole response with -1015 "cannot decode raw data".
        // Drop it (and the now-wrong Content-Length; `writeResponse` recomputes it)
        // so the captured flow and the client both see honest headers.
        let rawHeaders = http.map { HTTPUtil.headerPairs(from: $0) } ?? []
        return ForwardResult(
            statusCode: http?.statusCode ?? 200,
            headers: HTTPUtil.sanitizeDecodedResponseHeaders(rawHeaders),
            body: data
        )
    }
}
