import Foundation
import NIOHTTPCompression

/// An upstream response Loom decompressed past its ceiling, said in words the
/// operator can act on.
///
/// `NIOHTTPDecompression.DecompressionError.limit` has no associated values and no
/// `errorDescription`, so it reached every Loom surface — the flow's `error`, the
/// `502` body, HAR — as the single word **"limit"**. The exchange it kills is one
/// the origin serves fine and every client reads fine, which makes "limit" both the
/// least informative and the most misleading thing to say: nothing in it points at
/// Loom as the cause, so the operator goes looking at their own app.
///
/// It states what Loom did and what to do about it. The "what to do" is deliberate
/// and narrow — Loom pins `Accept-Encoding` to what it can inflate, so an operator
/// who genuinely needs a body this large past the proxy has exactly one lever: take
/// the host out of the SSL-proxying scope and let the client decompress it itself.
struct UpstreamDecompressionError: Error, LocalizedError {
    let host: String
    let limitBytes: Int

    var errorDescription: String? {
        """
        Loom stopped decompressing \(host)'s response: it inflated past Loom's \
        \(limitBytes / (1 << 20)) MB ceiling. The origin and the client are both fine with \
        this body — Loom decompresses on the client's behalf (it pins Accept-Encoding \
        to gzip/deflate) and bounds the inflation. To pass a body this large through \
        untouched, take \(host) out of the SSL-proxying scope with set_ssl_scope so the \
        client decompresses it itself.
        """
    }

    /// Wrap only the limit case, and only it.
    ///
    /// Same rule as `UpstreamTLSError.wrapping`: an inflation error (`inflationError`)
    /// means the body was not valid gzip/deflate, which is a fact about the origin and
    /// must not be dressed up as Loom's ceiling.
    static func wrapping(_ error: Error, host: String, limitBytes: Int) -> Error {
        guard case NIOHTTPDecompression.DecompressionError.limit = error else { return error }
        return UpstreamDecompressionError(host: host, limitBytes: limitBytes)
    }
}
