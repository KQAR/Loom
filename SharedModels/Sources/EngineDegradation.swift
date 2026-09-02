import Foundation

/// Something the engine fell back from, still running but doing less than the
/// operator asked for.
///
/// **The engine fails open by design, and that is only safe while it is not
/// silent.** A corrupt CA regenerates, an unreadable rules file starts empty, a
/// bad SSL scope disables interception, a write that cannot reach disk is dropped —
/// each keeps capture alive, and each also changes what Loom is doing in a way
/// nobody asked for. Every one of those paths logged at error level and stopped
/// there, which means one reader: a human with Console open. The primary operator
/// is an agent, and the human is looking at a menu-bar panel.
///
/// The failure mode is specific, not theoretical. An unreadable `rules.json` means
/// traffic the operator believes is mocked hits the real upstream; a rules file
/// that cannot be *written* means this session behaves correctly and the next one
/// silently does not; an audit store that will not open means write tools run with
/// no trail, which is the whole of Loom's supervision story.
///
/// One entry per `Kind`, counted rather than repeated: an encode failure recurs per
/// flow, and a list that grows per event would be a leak on the one surface meant
/// to say "this is wrong".
public struct EngineDegradation: Equatable, Sendable, Codable, Identifiable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        /// The rules file could not be read — this session started with **no rules**,
        /// so traffic the operator expects to be mocked, mapped or blocked is going
        /// to the real upstream.
        case rulesUnreadable
        /// Rule edits are not reaching disk: correct now, gone after a relaunch.
        case rulesNotPersisted
        /// The stored SSL scope could not be decoded, so **interception is off** —
        /// HTTPS the operator expects to be decrypted is being relayed instead.
        case sslScopeUnreadable
        /// SSL-scope changes are not reaching disk.
        case sslScopeNotPersisted
        /// A stored client identity could not be decoded, so mutual-TLS connections
        /// that need it will fail.
        case clientCertificatesUnreadable
        /// Client-identity changes are not reaching disk. These carry private keys:
        /// re-importing after a relaunch is the recovery.
        case clientCertificatesNotPersisted
        /// Reverse-proxy endpoints are not reaching disk, so they will not come back
        /// after a relaunch — while the dev server pointing at them still will.
        case reverseProxiesNotPersisted
        /// The audit trail is unavailable or dropping entries. Write tools still run;
        /// nothing records that they did, which is the supervision guarantee.
        case auditUnavailable
        /// The root CA could not be loaded or generated: **HTTPS interception cannot
        /// work at all** until it can.
        case certificateAuthorityUnavailable
        /// A new root CA was generated because the stored one could not be read. Every
        /// client that trusted the old one has to trust this one — until then,
        /// intercepted HTTPS fails at the handshake with no obvious cause.
        case certificateAuthorityRegenerated
        /// Captured flows are not reaching disk, or stored rows could not be decoded.
        /// The window is right and the history is short.
        case flowHistoryIncomplete
    }

    public var kind: Kind
    /// The reason, in the operator's words. The most recent one when a kind recurs —
    /// the same failure with a changing reason is worth seeing latest-first.
    public var detail: String
    public var firstSeen: Date
    public var lastSeen: Date
    /// How many times this kind has happened this run. `1` is a one-off; a large
    /// number is a condition rather than an event, and they need different reactions.
    public var count: Int

    public var id: Kind { kind }

    public init(kind: Kind, detail: String, firstSeen: Date, lastSeen: Date, count: Int) {
        self.kind = kind
        self.detail = detail
        self.firstSeen = firstSeen
        self.lastSeen = lastSeen
        self.count = count
    }

    /// A short label for a surface with no room for `detail` (the console's alert
    /// row, a tooltip's first line).
    public var headline: String {
        switch kind {
        case .rulesUnreadable: "Rules could not be read — nothing is being mocked or mapped"
        case .rulesNotPersisted: "Rule changes aren't being saved"
        case .sslScopeUnreadable: "HTTPS interception is off — its settings could not be read"
        case .sslScopeNotPersisted: "HTTPS scope changes aren't being saved"
        case .clientCertificatesUnreadable: "A client certificate could not be read"
        case .clientCertificatesNotPersisted: "Client certificate changes aren't being saved"
        case .reverseProxiesNotPersisted: "Reverse-proxy endpoints aren't being saved"
        case .auditUnavailable: "Write actions aren't being recorded"
        case .certificateAuthorityUnavailable: "No root CA — HTTPS can't be decrypted"
        case .certificateAuthorityRegenerated: "A new root CA was generated — trust it again"
        case .flowHistoryIncomplete: "Captured traffic isn't fully reaching the history"
        }
    }
}
