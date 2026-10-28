import Compression
import Foundation

/// Undoing a request body's `Content-Encoding` for a **reader**.
///
/// The response side never needs this: the forwarder inflates it on the way in
/// (`NIOHTTPResponseDecompressor`), so the recorded body is already plain. A request
/// body is forwarded and recorded exactly as the client sent it — it has to be, or a
/// replay would send something the client never did — so a gzip upload is stored as
/// gzip. Every surface used to read those bytes as they were, and every surface got
/// it wrong the same way: the Inspector said `<766 bytes>`, `get_flow_detail` said
/// `binary`, `body_contains` could not find a word that was plainly in the JSON, and
/// `diff_flows` compared two compressed streams.
///
/// So the stored bytes stay the wire bytes, and this is the **one** decode every
/// reader goes through (`CapturedRequest.decodedBody`). A body it cannot decode is
/// shown as recorded, and the reason travels with it — an encoding that was declared
/// and not undone must never read as "this is binary".
public enum ContentDecoding {
    /// Why a declared encoding was not undone. The body is then shown as recorded.
    public enum Failure: Error, Equatable, Sendable, CustomStringConvertible {
        /// A coding Loom does not implement (`zstd`, `compress`, a typo).
        case unsupported(String)
        /// The bytes do not parse as the coding they claim to be.
        case corrupt(String)
        /// Inflating would pass `limit` bytes — a bomb, or just more than Loom would
        /// ever have recorded.
        case exceedsLimit(Int)
        /// The capture cap cut the body, and a compressed prefix is not a body.
        case truncatedCapture

        public var description: String {
            switch self {
            case let .unsupported(coding): "unsupported content-coding \(coding)"
            case let .corrupt(coding): "not valid \(coding) data"
            case let .exceedsLimit(limit): "decoded body would exceed \(limit) bytes"
            case .truncatedCapture: "the capture is truncated, so the encoded body cannot be decoded"
            }
        }
    }

    /// The `Content-Encoding` codings in the order they must be **undone** — the
    /// header lists them in the order they were applied, so `gzip, br` is br first.
    /// `identity` is dropped; an empty result means there is nothing to undo.
    public static func codings(_ header: String) -> [String] {
        header.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty && $0 != "identity" }
            .reversed()
    }

    /// Undo every coding in `header`, or throw why not. Never more than `limit`
    /// decoded bytes at any layer.
    public static func decode(
        _ data: Data, contentEncoding header: String, limit: Int = FlowLimits.capturedBodyBytes
    ) throws(Failure) -> Data {
        var body = data
        for coding in codings(header) {
            switch coding {
            case "gzip", "x-gzip": body = try gunzip(body, limit: limit)
            case "deflate": body = try inflateDeflate(body, limit: limit)
            case "br": body = try inflate(body, algorithm: COMPRESSION_BROTLI, coding: "br", limit: limit)
            default: throw .unsupported(coding)
            }
        }
        return body
    }

    // MARK: - Codings

    /// RFC 1952. `COMPRESSION_ZLIB` is raw DEFLATE only, so the header and trailer
    /// are Loom's to walk. The trailer is taken as the last 8 bytes because the
    /// decoder consumes all of its input and cannot say where the stream ended — so
    /// concatenated members (legal, and unseen in HTTP bodies) read as corrupt.
    private static func gunzip(_ data: Data, limit: Int) throws(Failure) -> Data {
        let bytes = [UInt8](data)
        let start = try gzipHeaderEnd(bytes)
        guard bytes.count - start > 8 else { throw .corrupt("gzip") }
        let trailer = bytes.count - 8
        let output = try inflate(Data(bytes[start ..< trailer]), algorithm: COMPRESSION_ZLIB, coding: "gzip", limit: limit)
        // ISIZE: the decoded length mod 2³². The check that costs nothing; Compression
        // has no CRC32 to compare the other half against.
        let size = bytes[(trailer + 4)...].reversed().reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        guard size == UInt32(truncatingIfNeeded: output.count) else { throw .corrupt("gzip") }
        return output
    }

    /// Where the DEFLATE stream begins.
    private static func gzipHeaderEnd(_ bytes: [UInt8]) throws(Failure) -> Int {
        guard bytes.count >= 10, bytes[0] == 0x1F, bytes[1] == 0x8B, bytes[2] == 8 else { throw .corrupt("gzip") }
        let flags = bytes[3]
        var at = 10
        if flags & 0x04 != 0 { // FEXTRA
            guard bytes.count - at >= 2 else { throw .corrupt("gzip") }
            at += 2 + (Int(bytes[at]) | Int(bytes[at + 1]) << 8)
        }
        for flag: UInt8 in [0x08, 0x10] where flags & flag != 0 { // FNAME, FCOMMENT
            guard let end = bytes[min(at, bytes.count)...].firstIndex(of: 0) else { throw .corrupt("gzip") }
            at = end + 1
        }
        if flags & 0x02 != 0 { at += 2 } // FHCRC
        guard at < bytes.count else { throw .corrupt("gzip") }
        return at
    }

    /// HTTP `deflate` is the zlib format (RFC 1950), but enough servers and clients
    /// send raw DEFLATE that every browser accepts both; the 2-byte header is
    /// recognisable (CM = 8, header a multiple of 31), so take either.
    private static func inflateDeflate(_ data: Data, limit: Int) throws(Failure) -> Data {
        var body = data
        if data.count >= 2 {
            let cmf = data[data.startIndex], flg = data[data.startIndex + 1]
            if cmf & 0x0F == 8, (UInt16(cmf) << 8 | UInt16(flg)) % 31 == 0 {
                // A preset dictionary is something only the two endpoints know.
                guard flg & 0x20 == 0 else { throw .corrupt("deflate") }
                body = data.dropFirst(2)
            }
        }
        return try inflate(body, algorithm: COMPRESSION_ZLIB, coding: "deflate", limit: limit)
    }

    /// One complete compressed stream; anything short of its end is corrupt.
    private static func inflate(
        _ data: Data, algorithm: compression_algorithm, coding: String, limit: Int
    ) throws(Failure) -> Data {
        guard !data.isEmpty else { throw .corrupt(coding) }
        let stream = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
        defer { stream.deallocate() }
        guard compression_stream_init(stream, COMPRESSION_STREAM_DECODE, algorithm) == COMPRESSION_STATUS_OK
        else { throw .corrupt(coding) }
        defer { compression_stream_destroy(stream) }

        let chunk = 64 * 1024
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: chunk)
        defer { buffer.deallocate() }
        var output = Data()
        let source = [UInt8](data)
        return try source.withUnsafeBufferPointer { (input) throws(Failure) -> Data in
            stream.pointee.src_ptr = input.baseAddress!
            stream.pointee.src_size = input.count
            while true {
                stream.pointee.dst_ptr = buffer
                stream.pointee.dst_size = chunk
                let status = compression_stream_process(stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                let produced = chunk - stream.pointee.dst_size
                guard output.count + produced <= limit else { throw .exceedsLimit(limit) }
                output.append(buffer, count: produced)
                switch status {
                case COMPRESSION_STATUS_END:
                    return output
                case COMPRESSION_STATUS_OK where produced > 0:
                    continue
                default:
                    // An error, or input exhausted with no end-of-stream: a stream cut short.
                    throw .corrupt(coding)
                }
            }
        }
    }
}

/// A request body as a reader should see it — decoded when its `Content-Encoding`
/// could be undone, the recorded bytes otherwise, and in either case saying which.
///
/// Shaped after the response side's `FlowTransport.responseContentEncoding` /
/// `responseEncodedBodyBytes`: the coding, and the size that crossed the wire.
public struct DecodedBody: Equatable, Sendable {
    /// What to show, search and compare.
    public var data: Data?
    /// The request's `Content-Encoding`, nil when it declared none (or only
    /// `identity`) — in which case `data` is the recorded body untouched.
    public var contentEncoding: String?
    /// Bytes on the wire, still encoded. Set **only** when `data` is decoded, so its
    /// presence is the statement "these bytes are not what was sent".
    public var encodedBodyBytes: Int?
    /// Why a declared encoding was not undone; `data` is then the recorded bytes.
    public var decodeFailure: ContentDecoding.Failure?

    /// Whether `data` differs from the recorded bytes.
    public var isDecoded: Bool { encodedBodyBytes != nil }
}

public extension CapturedRequest {
    /// The body every reader shows — see `ContentDecoding`. Computed rather than
    /// stored so `body` stays the wire bytes (replay sends it), and cheap for the
    /// common case: no `Content-Encoding`, no work.
    var decodedBody: DecodedBody {
        guard let body, !body.isEmpty,
              let header = headers.value(named: "Content-Encoding"),
              !ContentDecoding.codings(header).isEmpty
        else { return DecodedBody(data: body) }
        guard !isBodyTruncated else {
            return DecodedBody(data: body, contentEncoding: header, decodeFailure: .truncatedCapture)
        }
        do {
            let decoded = try ContentDecoding.decode(body, contentEncoding: header)
            return DecodedBody(data: decoded, contentEncoding: header, encodedBodyBytes: body.count)
        } catch {
            return DecodedBody(data: body, contentEncoding: header, decodeFailure: error)
        }
    }
}
