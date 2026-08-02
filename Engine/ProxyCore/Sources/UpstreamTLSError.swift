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
///
/// **One class of failure is the exception, and it is not a judgement call.** When
/// the handshake failed because *Loom* refused the server's certificate — expired,
/// self-signed, wrong hostname — the mutual-TLS hypothesis is not merely unhelpful,
/// it is provably wrong: Loom rejected the peer, so the peer never got as far as
/// asking for anything. Saying "Loom presented no client certificate; install one
/// with set_client_certificate" there sends the reader after a write action that
/// needs the operator's private key and cannot possibly help. So that class is
/// detected (`peerCertificateRejected`) and described for what it is. Every other
/// failure keeps the neutral wording above.
struct UpstreamTLSError: Error, LocalizedError {
    let host: String
    /// The identity presented, or nil if none matched this host.
    let identity: String?
    let underlying: Error

    var errorDescription: String? {
        var text = "TLS handshake with \(host) failed. "
        if Self.peerCertificateRejected(underlying) {
            // Loom is the side that said no, so nothing here is about *our* identity.
            text += "Loom could not verify \(host)'s own certificate — it is expired, "
            text += "self-signed, or not valid for this host. This is not a "
            text += "client-certificate problem: Loom rejected the server, not the "
            text += "other way round. To reach the origin anyway, take the host out of "
            text += "the SSL-proxying scope with set_ssl_scope so Loom tunnels it "
            text += "without decrypting, and the client can judge the certificate itself. "
        } else if let identity {
            text += "Loom presented client certificate \(identity). "
        } else {
            text += "Loom presented no client certificate — none is configured for this host. "
            text += "A server that requires mutual TLS fails exactly like this; "
            text += "install one with set_client_certificate if that is the case. "
        }
        text += "Underlying error: \(underlying)"
        return text
    }

    /// Whether the handshake died because Loom refused the *server's* certificate.
    ///
    /// Two typed cases plus one string check. The string is the unpleasant part and
    /// it is deliberate: BoringSSL's verify failure arrives as an opaque
    /// `sslError([…])` whose only distinguishing feature is the reason text, and
    /// NIOSSL exposes no typed reason for it. Matching narrowly on the reason is
    /// still better than the alternative, which is telling every reader of an
    /// expired certificate to go install a private key. A miss here is safe — it
    /// falls through to the neutral wording.
    static func peerCertificateRejected(_ error: Error) -> Bool {
        if let extra = error as? NIOSSLExtraError, extra == .failedToValidateHostname { return true }
        if let ssl = error as? NIOSSLError, case .unableToValidateCertificate = ssl { return true }
        return String(describing: error).contains("CERTIFICATE_VERIFY_FAILED")
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
