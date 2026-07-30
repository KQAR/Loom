import Foundation
import NIOSSL

/// A failed upstream TLS handshake, with the one piece of context the raw error
/// never carries: which client identity Loom presented, if any.
///
/// Why this exists: an mTLS failure used to reach the operator as
/// `NIOSSL.NIOSSLError error 3.` — no host, no hint, and nothing to act on. The
/// error string is also the *only* channel that already surfaces everywhere a
/// failure is read (`get_recent_flows`, `get_flow_detail`, the Inspector, HAR), so
/// putting the context here reaches every surface without a new `Flow` field.
///
/// **It states what Loom did, never what the server wanted.** Loom cannot reliably
/// tell "this origin requires a client certificate" from any other handshake
/// failure: the requirement arrives as a TLS alert, and under TLS 1.3 a rejection
/// can surface *after* the handshake looks complete — on the first read, looking
/// like a reset. So the message reports the identity (or its absence) as a fact and
/// leaves the inference to the reader. A confidently wrong diagnosis costs more
/// than none.
struct UpstreamTLSError: Error, LocalizedError {
    let host: String
    /// The identity presented, or nil if none matched this host.
    let identity: String?
    let underlying: Error

    var errorDescription: String? {
        var text = "TLS handshake with \(host) failed. "
        if let identity {
            text += "Loom presented client certificate \(identity). "
        } else {
            text += "Loom presented no client certificate — none is configured for this host. "
            text += "A server that requires mutual TLS fails exactly like this; "
            text += "install one with set_client_certificate if that is the case. "
        }
        text += "Underlying error: \(underlying)"
        return text
    }

    /// Wrap `error` when it is a TLS failure; hand anything else straight back.
    ///
    /// The filter is the load-bearing part. A DNS miss or a refused connection on an
    /// `https://` URL has nothing to do with certificates, and appending a
    /// mutual-TLS note to it would turn a clear error into a misleading one — so only
    /// NIOSSL's own errors qualify. Notably **not** included: a connection that dies
    /// mid-exchange (`ForwarderError.connectionClosed`). That is where a TLS 1.3
    /// post-handshake rejection would land, but it is also where every ordinary reset
    /// lands, and there is no way to tell them apart from here.
    static func wrapping(_ error: Error, host: String, isTLS: Bool, identity: String?) -> Error {
        guard isTLS, isTLSFailure(error) else { return error }
        return UpstreamTLSError(host: host, identity: identity, underlying: error)
    }

    private static func isTLSFailure(_ error: Error) -> Bool {
        error is NIOSSLError || error is NIOSSLExtraError || error is BoringSSLError
    }
}
