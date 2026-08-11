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
            method: method, url: url, headers: headers(request["headers"]), body: requestBody
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
            outcome = .completed(
                CapturedResponse(
                    statusCode: status,
                    httpVersion: response["httpVersion"] as? String,
                    headers: headers(response["headers"]),
                    body: content(response["content"])
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
            importedFrom: label
        ))
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
