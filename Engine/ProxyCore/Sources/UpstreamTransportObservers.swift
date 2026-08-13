import Foundation
import Synchronization
import NIOCore
import NIOHTTP1
import NIOSSL
import NIOTLS
import X509
import LoomSharedModels

/// What Loom's upstream handshake settled on, learned once per connection and
/// read by every exchange that runs over it.
///
/// A box rather than a stored value for the same reason `UpstreamInactiveNotifier`
/// is one: the handler that fills it is installed inside `channelInitializer`,
/// which runs before there is a `Channel` — let alone an `UpstreamConnection` — to
/// hang it off. And it is filled *later still*, when the handshake completes, so
/// even a stored property on the connection could not hold it.
final class UpstreamTLSInfoBox: Sendable {
    private let value = Mutex<UpstreamTLSInfo?>(nil)

    var info: UpstreamTLSInfo? { value.withLock { $0 } }

    func set(_ info: UpstreamTLSInfo) {
        value.withLock { $0 = info }
    }
}

/// Records the negotiated TLS version and the origin's leaf certificate the
/// moment the upstream handshake completes.
///
/// Sits immediately after `NIOSSLClientHandler`, which is where the completion
/// event is raised and where the pipeline still contains the handler the two
/// NIOSSL accessors look for. **Observation only** — it neither verifies nor
/// vetoes anything, which is deliberate: NIOSSL's custom-verification callback is
/// the other way to reach the peer chain, and taking it would mean owning trust
/// evaluation for every upstream connection Loom makes. Reading the certificate
/// after NIOSSL has already validated it costs nothing and risks nothing.
///
/// Runs once per connection, not once per request, so the DER parse below is paid
/// on a fresh handshake and never on a pooled reuse.
// @unchecked Sendable: event-loop confined, no mutable state of its own — see
// ProxyCore/CLAUDE.md § Sendable escape hatches.
final class UpstreamTLSObserver: ChannelInboundHandler, RemovableChannelHandler, @unchecked Sendable {
    typealias InboundIn = NIOAny

    private let box: UpstreamTLSInfoBox
    private let serverName: String?
    private let clientCertificate: String?

    init(box: UpstreamTLSInfoBox, serverName: String?, clientCertificate: String?) {
        self.box = box
        self.serverName = serverName
        self.clientCertificate = clientCertificate
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if case TLSUserEvent.handshakeCompleted = event {
            let sync = context.pipeline.syncOperations
            box.set(UpstreamTLSInfo(
                version: Self.versionName((try? sync.nioSSL_tlsVersion()) ?? nil),
                serverName: serverName,
                clientCertificate: clientCertificate,
                certificate: Self.summarize((try? sync.nioSSL_peerCertificate()) ?? nil)
            ))
        }
        context.fireUserInboundEventTriggered(event)
    }

    /// The spelling every TLS tool prints, rather than the enum's case name.
    static func versionName(_ version: TLSVersion?) -> String? {
        switch version {
        case .tlsv1: return "TLSv1.0"
        case .tlsv11: return "TLSv1.1"
        case .tlsv12: return "TLSv1.2"
        case .tlsv13: return "TLSv1.3"
        case .none: return nil
        @unknown default: return nil
        }
    }

    /// Summarize the peer leaf through swift-certificates, which this module
    /// already depends on for minting. NIOSSL's own `NIOSSLCertificate` exposes
    /// only the serial, the validity window and the DER — no subject or issuer —
    /// and the issuer is the field that answers "is something else in this path".
    ///
    /// Every step is failure-tolerant on purpose: a certificate Loom cannot parse
    /// is not a reason to disturb a connection NIOSSL already validated. The
    /// summary simply comes back thinner, and an absent field means unmeasured.
    static func summarize(_ certificate: NIOSSLCertificate?) -> PeerCertificateInfo? {
        guard let certificate else { return nil }
        guard let der = try? certificate.toDERBytes(),
              let parsed = try? Certificate(derEncoded: der) else {
            // Still worth what NIOSSL gives directly: the validity window is the
            // half of this an operator checks most often.
            return PeerCertificateInfo(
                notBefore: Date(timeIntervalSince1970: TimeInterval(certificate.notValidBefore)),
                notAfter: Date(timeIntervalSince1970: TimeInterval(certificate.notValidAfter)),
                serialNumber: hex(certificate.serialNumber)
            )
        }
        return PeerCertificateInfo(
            subject: parsed.subject.description,
            issuer: parsed.issuer.description,
            notBefore: parsed.notValidBefore,
            notAfter: parsed.notValidAfter,
            serialNumber: hex(parsed.serialNumber.bytes)
        )
    }

    private static func hex(_ bytes: some Sequence<UInt8>) -> String? {
        let text = bytes.map { String(format: "%02X", $0) }.joined()
        return text.isEmpty ? nil : text
    }
}

/// Counts response body bytes **as they arrive from the socket**, before
/// `NIOHTTPResponseDecompressor` inflates them.
///
/// This is the only place the encoded size still exists. The forwarder
/// decompresses so that captures are readable, and then strips
/// `Content-Length`/`Content-Encoding` because they no longer describe the bytes
/// — which leaves nothing on any surface saying how much actually crossed the
/// wire. `Content-Length` would not have answered it either: a chunked response
/// carries none, and that is most of them.
///
/// Position is the whole contract: between `addHTTPClientHandlers()` (so it sees
/// framed `HTTPClientResponsePart`s rather than raw bytes) and the decompressor
/// (so those parts are still encoded). Moving it below the decompressor turns it
/// into a second, worse copy of the captured body's length.
// @unchecked Sendable: event-loop confined; `pending` is only ever touched from
// the channel's own loop — see ProxyCore/CLAUDE.md § Sendable escape hatches.
final class UpstreamEncodedBodyCounter: ChannelInboundHandler, RemovableChannelHandler, @unchecked Sendable {
    typealias InboundIn = HTTPClientResponsePart
    typealias InboundOut = HTTPClientResponsePart

    private let slot: UpstreamExchangeSlot
    private var pending = 0

    init(slot: UpstreamExchangeSlot) {
        self.slot = slot
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case .head:
            // One counter serves every exchange on a pooled connection, so the
            // count belongs to the response, not to the handler's lifetime.
            pending = 0
        case let .body(buffer):
            pending += buffer.readableBytes
        case .end:
            slot.receivedEncodedBodyBytes(pending)
            pending = 0
        }
        context.fireChannelRead(data)
    }
}
