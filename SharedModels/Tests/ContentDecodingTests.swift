import Compression
import Foundation
import Testing
@testable import LoomSharedModels

/// A request body is stored as it crossed the wire; `CapturedRequest.decodedBody` is
/// what every reader shows. Each coding, the layering order, and each way it falls
/// back to the recorded bytes — always saying why.
struct ContentDecodingTests {
    private let json = Data(#"{"event":"fb_mobile_activate_app","n":[1,2,3,4,5,6,7,8,9]}"#.utf8)

    // MARK: - Encoders (Compression's ZLIB is raw DEFLATE; the wrappers are ours)

    private static func encode(_ data: Data, _ algorithm: compression_algorithm) -> Data {
        let capacity = data.count + 1024
        var output = [UInt8](repeating: 0, count: capacity)
        let count = data.withUnsafeBytes { source in
            compression_encode_buffer(
                &output, capacity, source.bindMemory(to: UInt8.self).baseAddress!, data.count, nil, algorithm
            )
        }
        precondition(count > 0)
        return Data(output[..<count])
    }

    private static func gzip(_ data: Data) -> Data {
        var out = Data([0x1F, 0x8B, 8, 0x08, 0, 0, 0, 0, 0, 3]) + Data("name.json".utf8) + Data([0])
        out += encode(data, COMPRESSION_ZLIB)
        let le = { (value: UInt32) in Data((0 ..< 4).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) }) }
        out += le(crc32(data)) + le(UInt32(truncatingIfNeeded: data.count))
        return out
    }

    private static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0 ..< 8 { crc = crc & 1 == 1 ? (crc >> 1) ^ 0xEDB8_8320 : crc >> 1 }
        }
        return ~crc
    }

    private static func zlibDeflate(_ data: Data) -> Data {
        Data([0x78, 0x9C]) + encode(data, COMPRESSION_ZLIB) + Data([0, 0, 0, 0])
    }

    private static func flow(_ request: CapturedRequest) -> Flow {
        Flow(request: request, startedAt: Date())
    }

    private func request(_ body: Data, encoding: String?, fullBodyBytes: Int? = nil) -> CapturedRequest {
        CapturedRequest(
            method: "POST", url: "https://ep1.example.test/activities",
            headers: encoding.map { [HeaderPair(name: "content-encoding", value: $0)] } ?? [],
            body: body, fullBodyBytes: fullBodyBytes
        )
    }

    // MARK: - Codings

    @Test func gzip_isDecoded_andReportsTheWireSize() {
        let wire = Self.gzip(json)
        let decoded = request(wire, encoding: "gzip").decodedBody
        #expect(decoded.data == json)
        #expect(decoded.contentEncoding == "gzip")
        #expect(decoded.encodedBodyBytes == wire.count)
        #expect(decoded.decodeFailure == nil)
    }

    @Test func deflate_acceptsZlibWrappedAndRaw() {
        #expect(request(Self.zlibDeflate(json), encoding: "deflate").decodedBody.data == json)
        #expect(request(Self.encode(json, COMPRESSION_ZLIB), encoding: "Deflate").decodedBody.data == json)
    }

    @Test func brotli_isDecoded() {
        let decoded = request(Self.encode(json, COMPRESSION_BROTLI), encoding: "br").decodedBody
        #expect(decoded.data == json)
        #expect(decoded.isDecoded)
    }

    /// `gzip, br` was gzipped first, so br is undone first.
    @Test func layeredCodings_areUndoneInReverse() {
        let wire = Self.encode(Self.gzip(json), COMPRESSION_BROTLI)
        let decoded = request(wire, encoding: "gzip, identity, br").decodedBody
        #expect(decoded.data == json)
        #expect(decoded.encodedBodyBytes == wire.count)
    }

    // MARK: - Fallbacks: the recorded bytes, and the reason

    @Test func corruptData_fallsBackAndSaysSo() {
        var wire = Self.gzip(json)
        wire.removeLast(12) // a stream cut short
        let decoded = request(wire, encoding: "gzip").decodedBody
        #expect(decoded.data == wire)
        #expect(decoded.encodedBodyBytes == nil)
        #expect(decoded.decodeFailure == .corrupt("gzip"))

        let notGzip = request(json, encoding: "gzip").decodedBody
        #expect(notGzip.decodeFailure == .corrupt("gzip"))
        #expect(notGzip.data == json)
    }

    @Test func unsupportedCoding_fallsBackAndSaysSo() {
        let decoded = request(json, encoding: "zstd").decodedBody
        #expect(decoded.data == json)
        #expect(decoded.decodeFailure == .unsupported("zstd"))
    }

    /// The ceiling is the capture cap: a decoded body bigger than anything Loom would
    /// have recorded is not inflated. Zeros compress ~1000×, so this is a few KB.
    @Test func overTheLimit_fallsBackAndSaysSo() {
        let wire = Self.gzip(Data(count: FlowLimits.capturedBodyBytes + 1))
        let decoded = request(wire, encoding: "gzip").decodedBody
        #expect(decoded.data == wire)
        #expect(decoded.decodeFailure == .exceedsLimit(FlowLimits.capturedBodyBytes))
    }

    @Test func truncatedCapture_isNotDecoded() {
        let wire = Self.gzip(json)
        let decoded = request(wire, encoding: "gzip", fullBodyBytes: wire.count + 100).decodedBody
        #expect(decoded.data == wire)
        #expect(decoded.decodeFailure == .truncatedCapture)
    }

    @Test func noEncoding_isTheRecordedBodyUntouched() {
        let decoded = request(json, encoding: nil).decodedBody
        #expect(decoded == DecodedBody(data: json))
        #expect(request(json, encoding: "identity").decodedBody == DecodedBody(data: json))
    }

    // MARK: - Readers

    @Test func bodySearch_findsTextInsideAnEncodedBody() {
        let flow = Self.flow(request(Self.gzip(json), encoding: "gzip"))
        #expect(FlowQuery(bodyContains: "fb_mobile_activate_app").bodyPredicate().matches(flow))
    }

    @Test func diff_comparesDecodedBodies() {
        let gzipped = Self.flow(request(Self.gzip(json), encoding: "gzip"))
        let brotli = Self.flow(request(Self.encode(json, COMPRESSION_BROTLI), encoding: "br"))
        let comparison = FlowComparison.compare(base: gzipped, compared: brotli)
        #expect(comparison.request.body == nil)
        #expect(!comparison.request.headers.isEmpty)
    }

    @Test func har_exportsDecodedText_andRoundTripsTheWireBytes() throws {
        let wire = Self.gzip(json)
        let har = HARExport.encode([Self.flow(request(wire, encoding: "gzip"))], appVersion: "test")
        let object = try #require(JSONSerialization.jsonObject(with: har) as? [String: Any])
        let entries = try #require((object["log"] as? [String: Any])?["entries"] as? [[String: Any]])
        let post = try #require((entries.first?["request"] as? [String: Any])?["postData"] as? [String: Any])
        #expect(post["text"] as? String == String(decoding: json, as: UTF8.self))

        let imported = try HARImport.decode(har, label: "x.har")
        #expect(imported.flows.first?.request.body == wire)
    }
}
