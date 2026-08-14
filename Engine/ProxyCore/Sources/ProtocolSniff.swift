import Foundation

/// What the client appears to be speaking, judged from the first bytes it sends.
enum ClientProtocolGuess: Equatable {
    /// A TLS handshake record — MITM-able if the host is in the SSL scope.
    case tls
    /// An HTTP/1.x request line — capturable in cleartext.
    case http
    /// The HTTP/2 connection preface in cleartext — h2c with prior knowledge.
    /// Capturable: the h2 stack demuxes it exactly as the ALPN-negotiated path
    /// does, minus the TLS.
    case h2c
    /// Anything else: relay the bytes untouched.
    case opaque
    /// Not enough bytes to decide yet.
    case needMore
}

/// Guess a connection's protocol from its opening bytes.
///
/// This exists because SOCKS5 hands Loom a *host and port* and nothing else: the
/// client waits for the success reply before sending a byte, so the reply has to
/// go out before there is anything to inspect. Deciding capture strategy from the
/// port number alone would mean capturing nothing on the many services that don't
/// run HTTP on 80 and TLS on 443 — the reason to add SOCKS at all is the traffic
/// the HTTP proxy port never sees.
///
/// The HTTP test is deliberately generic (an uppercase method token followed by a
/// space) rather than a fixed method list: WebDAV, `PROPPATCH`, and whatever an
/// internal service invented all read the same on the wire, and a request that
/// *looks* like HTTP but isn't gets a 400 from the codec — the same answer the
/// dedicated proxy port would give it.
enum ProtocolSniff {
    /// Longest prefix worth buffering before giving up and relaying. A method
    /// token plus its space fits well inside this; TLS needs two bytes.
    static let maxBytes = 16

    static func classify(_ bytes: [UInt8]) -> ClientProtocolGuess {
        guard let first = bytes.first else { return .needMore }

        // TLS record: handshake content type, then the legacy record version's
        // major byte (0x03 for every TLS version, 1.3 included).
        if first == 0x16 {
            guard bytes.count >= 2 else { return .needMore }
            return bytes[1] == 0x03 ? .tls : .opaque
        }

        // HTTP/2 prior-knowledge preface (RFC 9113 §3.4). Reads exactly like an
        // HTTP request line to the test below, and the h1 codec would reject the
        // frames that follow — so it has to be separated out *before* that test,
        // and it gets the h2 stack rather than a relay.
        //
        // The real preface is 24 bytes (`PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n`); this
        // matches the first 14, which is enough to be unambiguous and fits inside
        // `maxBytes`. Waiting for all 24 would mean buffering past the point where
        // every other verdict is already decided, for no extra certainty.
        if bytes.count >= h2Preface.count {
            if Array(bytes.prefix(h2Preface.count)) == h2Preface { return .h2c }
        } else if Array(h2Preface.prefix(bytes.count)) == bytes {
            return .needMore
        }

        guard isUppercaseLetter(first) else { return .opaque }
        var index = 0
        while index < bytes.count, isUppercaseLetter(bytes[index]) { index += 1 }
        if index == bytes.count { return bytes.count >= maxBytes ? .opaque : .needMore }
        // Shortest real method is 3 characters (GET/PUT), so a 1–2 letter token
        // followed by a space is something else wearing HTTP's clothes.
        return bytes[index] == 0x20 && index >= 3 ? .http : .opaque
    }

    private static let h2Preface = Array("PRI * HTTP/2.0".utf8)

    private static func isUppercaseLetter(_ byte: UInt8) -> Bool {
        (0x41...0x5A).contains(byte)
    }
}
