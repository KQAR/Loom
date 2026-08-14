import Foundation
import Testing
@testable import LoomProxyCore

/// The SOCKS5 handshake is three small messages, and every one of them can arrive
/// split across reads. These pin both halves of that: the values parsed out of a
/// complete message, and `.needMore` for every truncation of it.
@Suite("SOCKS5 codec")
struct SOCKS5CodecTests {
    @Test func parsesGreetingAndReportsOfferedMethods() {
        let bytes: [UInt8] = [5, 2, 0x00, 0x02]
        guard case let .value(greeting, consumed) = SOCKS5.parseGreeting(bytes) else {
            Issue.record("expected a parsed greeting, got \(SOCKS5.parseGreeting(bytes))")
            return
        }
        #expect(greeting.methods == [0x00, 0x02])
        #expect(greeting.offersNoAuthentication)
        #expect(consumed == 4)
    }

    @Test func greetingWithoutNoAuthIsParsedButUnusable() {
        guard case let .value(greeting, _) = SOCKS5.parseGreeting([5, 1, 0x02]) else {
            Issue.record("expected a parsed greeting")
            return
        }
        #expect(!greeting.offersNoAuthentication, "username/password only — Loom offers no auth")
    }

    @Test func everyTruncationOfAGreetingAsksForMore() {
        let complete: [UInt8] = [5, 2, 0x00, 0x02]
        for length in 0..<complete.count {
            #expect(SOCKS5.parseGreeting(Array(complete.prefix(length))) == .needMore,
                    "\(length) of \(complete.count) bytes should not parse")
        }
    }

    @Test func rejectsNonVersion5Greeting() {
        // A SOCKS4 client's first byte. Refusing beats guessing: SOCKS4 frames its
        // request differently and has no "speak 5 instead" reply.
        #expect(SOCKS5.parseGreeting([4, 1, 0x00]) == .failure(.unsupportedVersion(4)))
    }

    @Test func rejectsEmptyMethodList() {
        #expect(SOCKS5.parseGreeting([5, 0]) == .failure(.emptyMethodList))
    }

    @Test func parsesDomainRequest() {
        var bytes: [UInt8] = [5, 0x01, 0x00, 0x03, 11]
        bytes.append(contentsOf: Array("example.test".utf8.prefix(11)))
        bytes.append(contentsOf: [0x01, 0xBB]) // 443
        guard case let .value(request, consumed) = SOCKS5.parseRequest(bytes) else {
            Issue.record("expected a parsed request, got \(SOCKS5.parseRequest(bytes))")
            return
        }
        #expect(request.command == .connect)
        #expect(request.host == "example.tes")
        #expect(request.port == 443)
        #expect(consumed == bytes.count)
    }

    @Test func parsesIPv4Request() {
        let bytes: [UInt8] = [5, 0x01, 0x00, 0x01, 127, 0, 0, 1, 0x1F, 0x90] // 8080
        guard case let .value(request, _) = SOCKS5.parseRequest(bytes) else {
            Issue.record("expected a parsed request")
            return
        }
        #expect(request.host == "127.0.0.1")
        #expect(request.port == 8080)
    }

    @Test func parsesIPv6Request() {
        var bytes: [UInt8] = [5, 0x01, 0x00, 0x04]
        bytes.append(contentsOf: [UInt8](repeating: 0, count: 15))
        bytes.append(1) // ::1
        bytes.append(contentsOf: [0x00, 0x50]) // 80
        guard case let .value(request, _) = SOCKS5.parseRequest(bytes) else {
            Issue.record("expected a parsed request")
            return
        }
        #expect(request.host == "0:0:0:0:0:0:0:1", "full form, no :: compression — still a valid literal")
        #expect(request.port == 80)
    }

    @Test func everyTruncationOfARequestAsksForMore() {
        var complete: [UInt8] = [5, 0x01, 0x00, 0x03, 4]
        complete.append(contentsOf: Array("host".utf8))
        complete.append(contentsOf: [0x00, 0x50])
        for length in 0..<complete.count {
            #expect(SOCKS5.parseRequest(Array(complete.prefix(length))) == .needMore,
                    "\(length) of \(complete.count) bytes should not parse")
        }
    }

    @Test func parsesUnsupportedCommandsSoTheyCanBeRefusedProperly() {
        // UDP ASSOCIATE is what a QUIC client would ask for; Loom must say
        // "command not supported" rather than hang or misread it as CONNECT.
        let bytes: [UInt8] = [5, 0x03, 0x00, 0x01, 1, 2, 3, 4, 0x01, 0xBB]
        guard case let .value(request, _) = SOCKS5.parseRequest(bytes) else {
            Issue.record("expected a parsed request")
            return
        }
        #expect(request.command == .udpAssociate)
    }

    @Test func rejectsUnknownCommandAndAddressType() {
        #expect(SOCKS5.parseRequest([5, 0x09, 0x00, 0x01]) == .failure(.unsupportedCommand(9)))
        #expect(SOCKS5.parseRequest([5, 0x01, 0x00, 0x07]) == .failure(.unsupportedAddressType(7)))
        #expect(SOCKS5.parseRequest([5, 0x01, 0x00, 0x03, 0]) == .failure(.malformedAddress))
    }

    @Test func encodesServerMessages() {
        #expect(SOCKS5.methodSelection(.noAuthentication) == [5, 0x00])
        #expect(SOCKS5.methodSelection(.unacceptable) == [5, 0xFF])
        #expect(SOCKS5.reply(.succeeded) == [5, 0x00, 0x00, 0x01, 0, 0, 0, 0, 0, 0])
        #expect(SOCKS5.reply(.commandNotSupported) == [5, 0x07, 0x00, 0x01, 0, 0, 0, 0, 0, 0])
    }
}

/// SOCKS hands over a host and port and nothing else, so what to *do* with the
/// connection is decided from its first bytes. These pin that decision, including
/// the "not yet" answers — routing early on a 1-byte read would misclassify every
/// client whose method token arrives split.
@Suite("Protocol sniffing")
struct ProtocolSniffTests {
    @Test func recognizesTLSHandshakeRecords() {
        #expect(ProtocolSniff.classify([0x16, 0x03, 0x01]) == .tls, "TLS 1.0 record version")
        #expect(ProtocolSniff.classify([0x16, 0x03, 0x04]) == .tls, "TLS 1.3 still writes 0x03 here")
        #expect(ProtocolSniff.classify([0x16]) == .needMore)
        #expect(ProtocolSniff.classify([0x16, 0x99]) == .opaque, "handshake byte but not a TLS version")
    }

    @Test func recognizesHTTPRequestLines() {
        #expect(ProtocolSniff.classify(Array("GET / HTTP/1.1".utf8)) == .http)
        #expect(ProtocolSniff.classify(Array("POST /x".utf8)) == .http)
        // Generic on purpose: a method list would misclassify WebDAV and anything
        // an internal service invented.
        #expect(ProtocolSniff.classify(Array("PROPPATCH /x".utf8)) == .http)
        #expect(ProtocolSniff.classify(Array("WHATEVER /x".utf8)) == .http)
    }

    @Test func waitsWhileAMethodTokenCouldStillBeArriving() {
        #expect(ProtocolSniff.classify([]) == .needMore)
        #expect(ProtocolSniff.classify(Array("GE".utf8)) == .needMore)
        #expect(ProtocolSniff.classify(Array("GET".utf8)) == .needMore, "no space yet — the token may continue")
    }

    @Test func h2cPriorKnowledgeGetsTheH2StackNotTheH1One() {
        // The preface reads exactly like a request line, and the h1 codec would
        // choke on the frames after it — so it has to be told apart *before* the
        // request-line test, and it gets the h2 stack rather than a blind relay.
        #expect(ProtocolSniff.classify(Array("PRI * HTTP/2.0\r\n".utf8)) == .h2c)
        #expect(ProtocolSniff.classify(Array("PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n".utf8)) == .h2c,
                "the full 24-byte preface, not just the prefix that decides it")
        #expect(ProtocolSniff.classify(Array("PRI".utf8)) == .needMore)
        #expect(ProtocolSniff.classify(Array("PRI * HTTP/2".utf8)) == .needMore,
                "a partial preface must not fall through to the request-line test")
        #expect(ProtocolSniff.classify(Array("PROPFIND /a".utf8)) == .http, "shares a prefix with PRI, isn't it")
    }

    @Test func anythingElseIsOpaque() {
        #expect(ProtocolSniff.classify([0x00, 0x01, 0x02]) == .opaque)
        #expect(ProtocolSniff.classify(Array("SSH-2.0-OpenSSH".utf8)) == .opaque, "lowercase before any space")
        #expect(ProtocolSniff.classify(Array("AB CD".utf8)) == .opaque, "2-letter token isn't a method")
        #expect(ProtocolSniff.classify([UInt8](repeating: 0x41, count: ProtocolSniff.maxBytes)) == .opaque,
                "gives up rather than buffering forever")
    }
}
