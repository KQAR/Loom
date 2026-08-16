import Foundation
import Synchronization

/// Reads HAR 1.2 (HTTP Archive) back into `Flow`s — the other half of `HARExport`.
///
/// Why: a HAR is how a capture crosses machines. A colleague's Chrome DevTools
/// export, a CI artifact, or an evidence bundle Loom itself produced can be loaded
/// into the store and then inspected, diffed and **replayed** with the same tools as
/// live traffic. Without import, a bug report containing a HAR is something an agent
/// can only read as text.
///
/// Parsing is deliberately forgiving of everything except the shape that matters. A
/// HAR in the wild is written by a dozen tools with different opinions: missing
/// `timings`, absent `postData`, `content.text` base64-encoded or not, timestamps
/// with or without fractional seconds. An entry Loom can't make sense of is *skipped
/// and counted* (`Result.skipped`) rather than dropped silently or failing the whole
/// import — one weird entry in three hundred must not lose the other 299, and a
/// silent partial import would be worse still.
public enum HARImport {
    public struct Result: Equatable, Sendable {
        public var flows: [Flow]
        /// Entries present in the file that could not be parsed into a flow.
        public var skipped: Int
        /// Human-readable reasons, deduplicated, for reporting back.
        public var reasons: [String]

        public init(flows: [Flow], skipped: Int, reasons: [String]) {
            self.flows = flows
            self.skipped = skipped
            self.reasons = reasons
        }
    }

    public enum Failure: Error, Equatable {
        case notJSON
        case notHAR
    }

    /// Parse HAR bytes. `label` is recorded on every flow as `importedFrom`, so
    /// imported traffic is never mistaken for something that happened here.
    public static func decode(_ data: Data, label: String) throws -> Result {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Failure.notJSON
        }
        guard let log = root["log"] as? [String: Any], let entries = log["entries"] as? [[String: Any]] else {
            throw Failure.notHAR
        }

        var flows: [Flow] = []
        var skipped = 0
        var reasons: [String] = []
        for entry in entries {
            switch flow(from: entry, label: label) {
            case let .success(flow): flows.append(flow)
            case let .failure(reason):
                skipped += 1
                if !reasons.contains(reason) { reasons.append(reason) }
            }
        }
        // Oldest first, matching how the store ingests live traffic.
        flows.sort { $0.startedAt < $1.startedAt }
        return Result(flows: flows, skipped: skipped, reasons: reasons)
    }

    // MARK: - One entry

    private enum EntryResult {
        case success(Flow)
        case failure(String)
    }

    private static func flow(from entry: [String: Any], label: String) -> EntryResult {
        guard let request = entry["request"] as? [String: Any] else {
            return .failure("entry has no request")
        }
        guard let method = request["method"] as? String, !method.isEmpty else {
            return .failure("request has no method")
        }
        guard let url = request["url"] as? String, !url.isEmpty else {
            return .failure("request has no url")
        }

        let startedAt = date(entry["startedDateTime"]) ?? Date(timeIntervalSince1970: 0)
        let requestBody = postData(request["postData"])
        let captured = CapturedRequest(
            method: method, url: url,
            // HAR requires `httpVersion`, and plenty of exporters fill it with a
            // placeholder ("HTTP/1.1" for an h2 capture, or the empty string).
            // Nothing here can tell a stated version from a defaulted one, so it
            // is taken as-is and only an empty one is dropped.
            httpVersion: (request["httpVersion"] as? String).flatMap { $0.isEmpty ? nil : $0 },
            headers: headers(request["headers"]), body: requestBody,
            fullBodyBytes: wireBytes(
                declared: request["bodySize"], truncated: request["_bodyTruncated"], captured: requestBody
            ),
            // Loom's own `_trailers` extension (§ HARExport). Absent from every
            // other exporter's output, which is the honest answer there: HAR 1.2
            // has no trailer section, so a file without the extension genuinely
            // does not say whether one existed.
            trailers: optionalHeaders(request["_trailers"])
        )

        // Timings: `time` is the whole exchange, `timings.wait` the server think-time.
        // HAR uses -1 for "not measured", which must not become a real duration.
        let timings = entry["timings"] as? [String: Any]
        let waitMS = positiveMilliseconds(timings?["wait"])
        let totalMS = positiveMilliseconds(entry["time"]) ?? waitMS
        let firstByteAt = waitMS.map { startedAt.addingTimeInterval($0 / 1000) }
        let completedAt = startedAt.addingTimeInterval((totalMS ?? 0) / 1000)

        let outcome: FlowOutcome
        if let response = entry["response"] as? [String: Any],
           let status = (response["status"] as? Int) ?? (response["status"] as? Double).map(Int.init),
           status > 0 {
            let responseBody = content(response["content"])
            outcome = .completed(
                CapturedResponse(
                    statusCode: status,
                    httpVersion: response["httpVersion"] as? String,
                    headers: headers(response["headers"]),
                    body: responseBody,
                    // `content.size` rather than `bodySize`: HAR defines the first as
                    // the *uncompressed* payload and the second as what came off the
                    // wire after transfer encodings, and Loom's body is decompressed
                    // by the time it is captured. Loom's own export writes the same
                    // number into both, so a round trip is unaffected either way; a
                    // foreign gzipped entry is the case where they differ, and the
                    // decoded size is the one the body can be compared against.
                    fullBodyBytes: wireBytes(
                        declared: (response["content"] as? [String: Any])?["size"],
                        truncated: response["_bodyTruncated"],
                        captured: responseBody
                    ),
                    trailers: optionalHeaders(response["_trailers"])
                ),
                at: completedAt
            )
        } else if let error = entry["_error"] as? String {
            // Loom's own export marks a failed exchange this way; keep it a failure
            // rather than inventing a status code for it.
            outcome = .failed(FlowError(error), at: completedAt, partialResponse: nil)
        } else {
            outcome = .failed(FlowError("no response recorded in the HAR entry"), at: completedAt, partialResponse: nil)
        }

        return .success(Flow(
            id: UUID(), // A fresh id: the file's ids (if any) may collide with the store's.
            request: captured,
            startedAt: startedAt,
            outcome: outcome,
            firstByteAt: firstByteAt,
            importedFrom: label,
            // Loom's own export ships the whole `FlowTransport` under `_transport`,
            // so a round trip keeps it. A foreign HAR has no such key and at most a
            // `serverIPAddress`, which is worth reading on its own — it is the one
            // transport fact the format standardizes.
            transport: transport(entry)
        ))
    }

    /// `_transport` when Loom wrote the file, otherwise whatever the standard
    /// `serverIPAddress` field carries. Nil when neither is there, so an imported
    /// flow doesn't claim a measured-and-empty transport.
    private static func transport(_ entry: [String: Any]) -> FlowTransport? {
        if let raw = entry["_transport"],
           let data = try? JSONSerialization.data(withJSONObject: raw),
           let decoded = try? JSONDecoder().decode(FlowTransport.self, from: data),
           !decoded.isEmpty {
            return decoded
        }
        guard let ip = entry["serverIPAddress"] as? String, !ip.isEmpty else { return nil }
        return FlowTransport(remoteAddress: ip)
    }

    /// The same shape, but distinguishing "the key was absent" (nil — no trailer
    /// section) from "the key was there and empty" (`[]`). `headers` collapses both
    /// to `[]`, which is right for a required HAR field and wrong for this one.
    private static func optionalHeaders(_ raw: Any?) -> [HeaderPair]? {
        guard raw is [[String: Any]] else { return nil }
        return headers(raw)
    }

    private static func headers(_ raw: Any?) -> [HeaderPair] {
        guard let list = raw as? [[String: Any]] else { return [] }
        return list.compactMap { item in
            guard let name = item["name"] as? String else { return nil }
            return HeaderPair(name: name, value: item["value"] as? String ?? "")
        }
    }

    /// `postData.text`, honoring Loom's `_encoding: base64` extension so a binary
    /// request body survives an export/import round trip.
    private static func postData(_ raw: Any?) -> Data? {
        guard let post = raw as? [String: Any], let text = post["text"] as? String, !text.isEmpty else {
            return nil
        }
        if isBase64(post["_encoding"] ?? post["encoding"]), let decoded = Data(base64Encoded: text) {
            return decoded
        }
        return Data(text.utf8)
    }

    /// `content.text`, honoring the standard `encoding: base64` field (which Chrome
    /// and Loom both write for binary payloads).
    private static func content(_ raw: Any?) -> Data? {
        guard let content = raw as? [String: Any], let text = content["text"] as? String, !text.isEmpty else {
            return nil
        }
        if isBase64(content["encoding"]), let decoded = Data(base64Encoded: text) {
            return decoded
        }
        return Data(text.utf8)
    }

    /// `CapturedRequest`/`CapturedResponse.fullBodyBytes` for an imported entry —
    /// the bytes that crossed the wire, set **only** when the body in hand is a
    /// prefix of them.
    ///
    /// ## Why this exists
    ///
    /// `HARExport` writes `bodySize` / `content.size` as the wire size and marks a
    /// capped body with the `_bodyTruncated` vendor extension. Import read neither,
    /// so every imported flow came back with `fullBodyBytes == nil`, which
    /// `isBodyTruncated` reads as "this body is the whole payload".
    ///
    /// That is not a thin answer, it is a wrong one. `FlowComparison.compareBodies`
    /// takes both sides' `fullBodyBytes` precisely so two bodies capped at the same
    /// length are reported as `.tailNotCaptured` rather than identical — the prefixes
    /// match whatever the tails did. With the field dropped on import, `diff_flows`
    /// on a re-imported capture answers a confident "no difference" for two bodies
    /// that differ, which is the exact defect that check was added for. It also took
    /// `captureTruncated` off `get_recent_flows` and the truncation notice out of the
    /// Inspector for imported flows.
    ///
    /// ## Two sources, and one inference deliberately not made
    ///
    /// - **`_bodyTruncated: true`** is Loom's own marker and is authoritative: the
    ///   declared size is the wire size and the body is a prefix of it.
    /// - **No body but a declared size** is the foreign-HAR case worth reading —
    ///   DevTools omits `content.text` for large or unavailable payloads while still
    ///   reporting the size. An empty prefix is still a prefix, and saying so is what
    ///   keeps two such entries from comparing equal.
    /// - **A size that merely disagrees with a present body's length is ignored.**
    ///   For a foreign entry the two legitimately differ — compression, transfer
    ///   encodings, an exporter counting characters rather than bytes — so inferring
    ///   truncation from the mismatch would mark ordinary gzipped exchanges as
    ///   partial. A false "truncated" is cheaper than a false "complete", but it is
    ///   still a wrong claim on the surface whose whole job is to say when a
    ///   comparison cannot be trusted.
    private static func wireBytes(declared: Any?, truncated: Any?, captured: Data?) -> Int? {
        guard let size = positiveInt(declared), size > 0 else { return nil }
        let capturedCount = captured?.count ?? 0
        if truncated as? Bool == true { return max(size, capturedCount) }
        return capturedCount == 0 ? size : nil
    }

    private static func positiveInt(_ raw: Any?) -> Int? {
        switch raw {
        case let number as Int: return number >= 0 ? number : nil
        case let number as Double: return number >= 0 ? Int(number) : nil
        default: return nil
        }
    }

    private static func isBase64(_ raw: Any?) -> Bool {
        (raw as? String)?.caseInsensitiveCompare("base64") == .orderedSame
    }

    /// A duration in milliseconds, or nil for HAR's "not measured" (-1) and for
    /// anything non-numeric. Never negative: a negative timing would produce a
    /// `completedAt` before `startedAt` and make every derived figure nonsense.
    private static func positiveMilliseconds(_ raw: Any?) -> Double? {
        let value: Double
        switch raw {
        case let number as Double: value = number
        case let number as Int: value = Double(number)
        default: return nil
        }
        return value >= 0 ? value : nil
    }

    /// ISO-8601 with or without fractional seconds — both appear in real HARs, and
    /// `ISO8601DateFormatter` only accepts the one shape its `formatOptions` names, so
    /// parsing needs both.
    ///
    /// Held rather than constructed per call, for the reason `HARExport.iso8601`
    /// already records on the other side of the same file pair: the initializer sets up
    /// a locale, a calendar and a time zone, and an import runs this **once per entry**
    /// — a 10 000-entry HAR was allocating 20 000 formatters to parse 10 000
    /// timestamps. `formatOptions` is set once here and never varies per call, so the
    /// instances are reusable; the `Mutex` is what makes sharing them sound, since
    /// `ISO8601DateFormatter` is not `Sendable` and this type is confined to no queue
    /// or actor.
    private static let iso8601 = Mutex<(fractional: ISO8601DateFormatter, plain: ISO8601DateFormatter)>({
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return (fractional, ISO8601DateFormatter())
    }())

    private static func date(_ raw: Any?) -> Date? {
        guard let text = raw as? String else { return nil }
        return iso8601.withLock { $0.fractional.date(from: text) ?? $0.plain.date(from: text) }
    }
}
