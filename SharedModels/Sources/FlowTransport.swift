import Foundation

/// How an exchange actually travelled — the facts about the *connection* rather
/// than about the message.
///
/// This is the half of an exchange a capture proxy is uniquely placed to answer
/// and that no amount of reading headers can recover: which origin IP the bytes
/// went to, whether the socket was already open, what TLS was negotiated on
/// Loom's own upstream leg, and how many bytes crossed the wire *before* Loom
/// decompressed them. Without it a slow request and a fast one look identical in
/// the capture, and "why did TTFB jump" has no answer on any surface.
///
/// Every field is optional, and absent means **not measured**, never "no". Two
/// separate reasons a field can be nil, both real: the exchange never reached the
/// point where it is known (a connect failure has no TLS version), or the path
/// that produced it does not measure it at all (a mocked response never touched a
/// socket). A renderer must say "—", never "none".
public struct FlowTransport: Equatable, Codable, Sendable {
    /// TLS version the **client** negotiated with Loom's minted leaf, on the
    /// client↔Loom leg. Nil for a plaintext request, and for a client whose
    /// handshake Loom never terminated.
    public var clientTLSVersion: String?
    /// The origin's address as Loom connected to it — `"93.184.216.34:443"`. The
    /// thing a DNS answer resolves to, which the URL does not tell you and which
    /// is the whole diagnosis for a request reaching the wrong CDN edge or a
    /// stale `/etc/hosts` entry.
    public var remoteAddress: String?
    /// Whether this exchange ran on a connection that was already open (leased
    /// from `UpstreamConnectionPool`) rather than one it opened itself. The
    /// difference is a TCP connect plus a TLS handshake — measured at ~96 ms — and
    /// it is the reason two otherwise identical requests report different TTFBs.
    public var connectionReused: Bool?
    /// TLS on the Loom↔origin leg. Distinct from `clientTLSVersion` on purpose:
    /// they are two independent handshakes and they routinely disagree, which is
    /// exactly what an operator debugging a pinning or protocol issue needs to see.
    public var upstreamTLS: UpstreamTLSInfo?
    /// `Content-Encoding` the origin actually sent, captured **before**
    /// `NIOHTTPResponseDecompressor` inflated the body and
    /// `HTTPUtil.sanitizeDecodedResponseHeaders` stripped the header. Without it
    /// the captured flow gives no hint that the response was compressed at all.
    public var responseContentEncoding: String?
    /// Response body bytes as they crossed the wire — still encoded, so this is
    /// the number a bandwidth question is about. Compare with the captured body's
    /// length (or `CapturedResponse.fullBodyBytes`) for the compression ratio.
    public var responseEncodedBodyBytes: Int?
    /// What opening this connection cost, broken into phases.
    ///
    /// **Present only on the exchange that actually opened it** — a reused
    /// connection paid none of this, and attributing the original setup to a later
    /// request would inflate exactly the number someone is trying to explain.
    /// `connectionReused == true` and a nil `setup` are the same statement seen
    /// from two sides.
    public var setup: ConnectionSetup?
    /// Writing the request out: first byte handed to the socket → final flush
    /// acknowledged. Per exchange, so a reused connection has one too.
    ///
    /// Usually ~0 and worth having anyway: a large upload against a slow link is
    /// the one case where the client's own send is the answer to "why is this
    /// slow", and TTFB alone reports it as the server thinking.
    ///
    /// **Absent on the exchange that opened a TLS connection**, and that is a
    /// refusal rather than a gap: NIOSSL buffers writes until the handshake
    /// completes, so the clock there measures the handshake — which
    /// `setup.tlsHandshakeMS` already reports, correctly and once.
    public var requestSendMS: Int?
    /// The client leg is HTTP/1.1 **because Loom made it so**, not because the client
    /// chose it.
    ///
    /// Loom withholds ALPN `h2` from a host whose first header block its HPACK decoder
    /// refused (`HTTP2DowngradeRegistry` — SwiftNIO's 16 KB pre-ACK limit, an upstream
    /// gap Loom has no knob for). The alternative is a connection that dies, so the
    /// trade is worth taking; what it is not is invisible. `CapturedRequest
    /// .httpVersion` then reads `HTTP/1.1`, which is true of what happened and **false
    /// about what the app would have done** — and an operator comparing this capture
    /// with production is measuring exactly that difference.
    ///
    /// `Bool?` rather than `Bool`: a flag that only ever means true adds a key that was
    /// never there when it is false (AGENTS.md § renders).
    public var clientProtocolDowngraded: Bool?

    public init(
        clientTLSVersion: String? = nil,
        remoteAddress: String? = nil,
        connectionReused: Bool? = nil,
        upstreamTLS: UpstreamTLSInfo? = nil,
        responseContentEncoding: String? = nil,
        responseEncodedBodyBytes: Int? = nil,
        setup: ConnectionSetup? = nil,
        requestSendMS: Int? = nil,
        clientProtocolDowngraded: Bool? = nil
    ) {
        self.clientTLSVersion = clientTLSVersion
        self.remoteAddress = remoteAddress
        self.connectionReused = connectionReused
        self.upstreamTLS = upstreamTLS
        self.responseContentEncoding = responseContentEncoding
        self.responseEncodedBodyBytes = responseEncodedBodyBytes
        self.setup = setup
        self.requestSendMS = requestSendMS
        self.clientProtocolDowngraded = clientProtocolDowngraded
    }

    public var isEmpty: Bool { self == FlowTransport() }

    /// Fold a later, partial reading over this one. The transport of one exchange
    /// is learned in two instalments — most of it when the response head arrives,
    /// the encoded byte count only once the body has finished — so the relay
    /// merges rather than replaces. A nil field in `other` leaves this one's value
    /// alone, which is what makes the second instalment able to carry one field.
    public func merging(_ other: FlowTransport) -> FlowTransport {
        FlowTransport(
            clientTLSVersion: other.clientTLSVersion ?? clientTLSVersion,
            remoteAddress: other.remoteAddress ?? remoteAddress,
            connectionReused: other.connectionReused ?? connectionReused,
            upstreamTLS: other.upstreamTLS ?? upstreamTLS,
            responseContentEncoding: other.responseContentEncoding ?? responseContentEncoding,
            responseEncodedBodyBytes: other.responseEncodedBodyBytes ?? responseEncodedBodyBytes,
            setup: other.setup ?? setup,
            requestSendMS: other.requestSendMS ?? requestSendMS,
            clientProtocolDowngraded: other.clientProtocolDowngraded ?? clientProtocolDowngraded
        )
    }
}

/// What it cost to open the upstream connection, phase by phase.
///
/// The half of "why is this slow" that a single TTFB cannot answer: a 900 ms
/// first request to an origin is a completely different bug depending on whether
/// it was DNS, the TCP round trips or a TLS handshake — and until this existed,
/// all three were folded into the server's think-time and read as "the API is
/// slow". Every field is optional and absent means *not measured*.
public struct ConnectionSetup: Equatable, Codable, Sendable {
    /// Resolving the origin's name. Absent for an IP-literal origin, which has
    /// nothing to resolve, and for a resolution that failed (the connection then
    /// fails on its own and says so).
    public var dnsMS: Int?
    /// The TCP connect alone — `connect()` to the socket being writable. Does
    /// **not** include DNS (that is `dnsMS`) and does not include the TLS
    /// handshake (that is `tlsHandshakeMS`), which is a deliberate departure from
    /// HAR's `connect`, where `ssl` is a sub-interval. Two numbers that overlap
    /// are two numbers a reader has to be told about; the HAR exporter adds them
    /// back together, because that is the format's contract, not the model's.
    public var tcpMS: Int?
    /// ClientHello → handshake complete on Loom's leg to the origin. Absent for a
    /// plaintext upstream.
    public var tlsHandshakeMS: Int?

    public init(dnsMS: Int? = nil, tcpMS: Int? = nil, tlsHandshakeMS: Int? = nil) {
        self.dnsMS = dnsMS
        self.tcpMS = tcpMS
        self.tlsHandshakeMS = tlsHandshakeMS
    }

    public var isEmpty: Bool { self == ConnectionSetup() }

    /// Everything measured here, summed — what the first request to an origin paid
    /// before it could send a byte. Nil when nothing was measured; a phase that
    /// wasn't measured simply doesn't contribute, which is why this is a floor
    /// rather than a total.
    public var totalMS: Int? {
        let parts = [dnsMS, tcpMS, tlsHandshakeMS].compactMap { $0 }
        return parts.isEmpty ? nil : parts.reduce(0, +)
    }
}

/// What Loom's own TLS handshake with the origin settled on.
///
/// Deliberately **not** carrying the negotiated cipher suite: NIOSSL exposes the
/// version and the peer certificate off a live connection and nothing else, so a
/// cipher field could only ever be a guess reconstructed from the configured
/// suite list. A field that is right most of the time is worse than an absent one
/// on a surface an operator uses to decide whether a handshake behaved.
public struct UpstreamTLSInfo: Equatable, Codable, Sendable {
    /// `"TLSv1.3"` / `"TLSv1.2"` — as negotiated, not as configured.
    public var version: String?
    /// The SNI Loom sent. Nil for an IP-literal origin, which cannot take one —
    /// and that nil is informative, because a server matching on SNI will serve
    /// its default vhost instead.
    public var serverName: String?
    /// Label of the mutual-TLS client identity Loom presented, or nil for none.
    /// Stating the absence is the point: an mTLS origin that answers 403 looks
    /// exactly like an authorization bug until you can see that no certificate
    /// went with the request.
    public var clientCertificate: String?
    /// The leaf the origin presented. Loom validates it normally; this records
    /// what it saw, which is how an unexpected interception (a corporate MITM in
    /// front of Loom) becomes visible rather than merely working.
    public var certificate: PeerCertificateInfo?

    public init(
        version: String? = nil,
        serverName: String? = nil,
        clientCertificate: String? = nil,
        certificate: PeerCertificateInfo? = nil
    ) {
        self.version = version
        self.serverName = serverName
        self.clientCertificate = clientCertificate
        self.certificate = certificate
    }
}

/// A summary of the origin's leaf certificate — enough to answer "who signed
/// this and when does it expire", which is the question an expiring certificate
/// or an unexpected issuer poses. Not the certificate itself: the DER is large,
/// it would be recorded once per connection, and nothing downstream re-verifies.
public struct PeerCertificateInfo: Equatable, Codable, Sendable {
    public var subject: String?
    public var issuer: String?
    public var notBefore: Date?
    public var notAfter: Date?
    /// Hex, uppercase, no separators — the spelling `openssl x509 -serial` prints.
    public var serialNumber: String?

    public init(
        subject: String? = nil,
        issuer: String? = nil,
        notBefore: Date? = nil,
        notAfter: Date? = nil,
        serialNumber: String? = nil
    ) {
        self.subject = subject
        self.issuer = issuer
        self.notBefore = notBefore
        self.notAfter = notAfter
        self.serialNumber = serialNumber
    }

    /// Whether the certificate was already expired (or not yet valid) at the
    /// moment the exchange ran. Computed against the exchange's own clock rather
    /// than "now", because a flow read out of the store a week later must not
    /// re-answer a question about a connection that already happened.
    public func isValid(at date: Date) -> Bool {
        if let notBefore, date < notBefore { return false }
        if let notAfter, date > notAfter { return false }
        return true
    }
}
