import Foundation

/// The SOCKS5 wire format (RFC 1928), as pure bytes-in / values-out.
///
/// Deliberately free of NIO channel types: the handshake is three tiny messages
/// with a length-prefixed address in the middle, which is exactly the kind of
/// parsing that is easy to get subtly wrong and easy to test in isolation. Every
/// entry point takes *the bytes seen so far* and can answer `.needMore` — a TCP
/// peer is free to split a 3-byte greeting across three segments, and a parser
/// that assumes one read per message works on every client until it doesn't.
///
/// Only the subset Loom needs is modelled: version 5, no authentication, and the
/// `CONNECT` command. `BIND` / `UDP ASSOCIATE` are parsed (so they can be
/// *refused* correctly rather than hung up on) but not served — UDP in
/// particular is what a QUIC client would want, and Loom cannot capture that
/// (see the QUIC note in AGENTS.md).
enum SOCKS5 {
    static let version: UInt8 = 5

    enum Method: UInt8 {
        case noAuthentication = 0x00
        /// "None of your offers is acceptable" — the client must close.
        case unacceptable = 0xFF
    }

    enum Command: UInt8 {
        case connect = 0x01
        case bind = 0x02
        case udpAssociate = 0x03
    }

    enum Reply: UInt8 {
        case succeeded = 0x00
        case generalFailure = 0x01
        case commandNotSupported = 0x07
        case addressTypeNotSupported = 0x08
    }

    enum AddressType: UInt8 {
        case ipv4 = 0x01
        case domain = 0x03
        case ipv6 = 0x04
    }

    /// The client's opening message: which authentication methods it offers.
    struct Greeting: Equatable {
        var methods: [UInt8]

        var offersNoAuthentication: Bool { methods.contains(Method.noAuthentication.rawValue) }
    }

    /// The client's command: what it wants opened, and where.
    struct Request: Equatable {
        var command: Command
        /// Domain name as sent, or an IPv4/IPv6 literal. A literal means Loom has
        /// no hostname for the connection, so an SSL-scope decision on it can only
        /// match by address (SNI recovery is deliberately not attempted — the scope
        /// is host-shaped and a guessed name would be a lie on the flow).
        var host: String
        var port: Int
    }

    enum Failure: Error, Equatable {
        case unsupportedVersion(UInt8)
        case unsupportedCommand(UInt8)
        case unsupportedAddressType(UInt8)
        case emptyMethodList
        case malformedAddress
    }

    /// Parse outcome over a partial byte stream. `consumed` is how many leading
    /// bytes the caller should drop — the client may have pipelined more.
    enum Parsed<Value: Equatable>: Equatable {
        case needMore
        case value(Value, consumed: Int)
        case failure(Failure)
    }

    static func parseGreeting(_ bytes: [UInt8]) -> Parsed<Greeting> {
        guard bytes.count >= 2 else { return .needMore }
        guard bytes[0] == version else { return .failure(.unsupportedVersion(bytes[0])) }
        let count = Int(bytes[1])
        guard count > 0 else { return .failure(.emptyMethodList) }
        guard bytes.count >= 2 + count else { return .needMore }
        return .value(Greeting(methods: Array(bytes[2..<(2 + count)])), consumed: 2 + count)
    }

    static func parseRequest(_ bytes: [UInt8]) -> Parsed<Request> {
        guard bytes.count >= 4 else { return .needMore }
        guard bytes[0] == version else { return .failure(.unsupportedVersion(bytes[0])) }
        guard let command = Command(rawValue: bytes[1]) else { return .failure(.unsupportedCommand(bytes[1])) }
        // bytes[2] is RSV — reserved, ignored on purpose (not validated as 0x00:
        // refusing a client over a reserved byte buys nothing).
        guard let addressType = AddressType(rawValue: bytes[3]) else {
            return .failure(.unsupportedAddressType(bytes[3]))
        }

        var index = 4
        let host: String
        switch addressType {
        case .ipv4:
            guard bytes.count >= index + 4 else { return .needMore }
            host = bytes[index..<(index + 4)].map(String.init).joined(separator: ".")
            index += 4
        case .domain:
            guard bytes.count >= index + 1 else { return .needMore }
            let length = Int(bytes[index])
            index += 1
            guard length > 0 else { return .failure(.malformedAddress) }
            guard bytes.count >= index + length else { return .needMore }
            host = String(decoding: bytes[index..<(index + length)], as: UTF8.self)
            index += length
        case .ipv6:
            guard bytes.count >= index + 16 else { return .needMore }
            host = ipv6String(Array(bytes[index..<(index + 16)]))
            index += 16
        }

        guard bytes.count >= index + 2 else { return .needMore }
        let port = Int(bytes[index]) << 8 | Int(bytes[index + 1])
        return .value(Request(command: command, host: host, port: port), consumed: index + 2)
    }

    /// Server's answer to the greeting: the one method it picked.
    static func methodSelection(_ method: Method) -> [UInt8] {
        [version, method.rawValue]
    }

    /// Server's answer to a command. The bound address is reported as `0.0.0.0:0`
    /// — every client Loom cares about ignores it for `CONNECT`, and reporting the
    /// real upstream socket would leak nothing useful while requiring the reply to
    /// wait for the upstream connection (which the capture paths never make; the
    /// forwarder does, later).
    static func reply(_ reply: Reply) -> [UInt8] {
        [version, reply.rawValue, 0x00, AddressType.ipv4.rawValue, 0, 0, 0, 0, 0, 0]
    }

    /// Full 8-group form, no `::` compression — valid, unambiguous, and what NIO's
    /// `ClientBootstrap.connect(host:port:)` accepts back as a literal.
    private static func ipv6String(_ bytes: [UInt8]) -> String {
        stride(from: 0, to: 16, by: 2)
            .map { String(Int(bytes[$0]) << 8 | Int(bytes[$0 + 1]), radix: 16) }
            .joined(separator: ":")
    }
}
