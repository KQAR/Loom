import Foundation

/// What changed between two captured flows — the "observe" step of Loom's
/// capture → modify → replay → **diff** loop.
///
/// This lives in SharedModels, and is a typed value rather than a JSON blob, for
/// one reason: **the agent and the human have to be looking at the same diff.**
/// The MCP `diff_flows` tool and the Inspector's diff pane each used to compute
/// their own, and they disagreed — the tool reported header add/remove/change and
/// a line-level body diff, while the pane reported `body: changed` and skipped
/// response headers entirely. A supervising human comparing notes with an agent
/// was comparing two different answers to the same question.
///
/// So the semantics live here once. The MCP layer renders this to its JSON wire
/// shape; the Inspector renders it to rows. Neither computes anything.
///
/// **Two things are deliberately not differences.** Timing (`ttfbMS` /
/// `receiveMS` / `durationMS`) is excluded because two runs of the same exchange
/// essentially never share it — diffing it would make every comparison
/// non-identical and so make `isIdentical` worthless, which is the one thing a
/// reader trusts it for. And an absent body compares equal to a zero-byte one:
/// on the wire they are the same bytes, and a GET whose replay carried `Data()`
/// is not a change anybody wants reported.
public struct FlowComparison: Equatable, Sendable {
    public var baseID: UUID
    public var comparedID: UUID
    public var request: MessageComparison
    public var response: ResponseComparison
    /// Frame-log differences, for a comparison where either side is a WebSocket.
    public var webSocket: WebSocketComparison
    /// Transport-level error text, when one side failed and the other didn't (or
    /// they failed differently).
    public var error: ValueChange<String>?

    /// Nothing differs anywhere.
    ///
    /// Read it with `isPartial` — "nothing differs" is only as strong as what was
    /// captured, and a capped body means the bytes past the cap were never
    /// compared at all.
    public var isIdentical: Bool {
        request.isEmpty && response.isEmpty && webSocket.isEmpty && error == nil
    }

    /// At least one body compared here is a capture-capped prefix, so this
    /// comparison covers a prefix of what actually flowed. A reader that reports
    /// "identical" without saying this is claiming more than it checked.
    public var isPartial: Bool {
        request.body?.isTruncated == true || response.body?.isTruncated == true
    }

    public init(
        baseID: UUID,
        comparedID: UUID,
        request: MessageComparison,
        response: ResponseComparison,
        webSocket: WebSocketComparison = WebSocketComparison(),
        error: ValueChange<String>? = nil
    ) {
        self.baseID = baseID
        self.comparedID = comparedID
        self.request = request
        self.response = response
        self.webSocket = webSocket
        self.error = error
    }

    // MARK: - Pieces

    /// A scalar that differs. Either side may be absent (added/removed), which is
    /// why both are optional rather than the pair being.
    public struct ValueChange<Value: Equatable & Sendable>: Equatable, Sendable {
        public var base: Value?
        public var compared: Value?

        public init(base: Value?, compared: Value?) {
            self.base = base
            self.compared = compared
        }
    }

    /// One header name's values on each side. A header can legally repeat, so the
    /// values are a list — that way a duplicated or dropped repeat is visible
    /// instead of collapsing into "unchanged".
    public struct HeaderChange: Equatable, Sendable {
        public var name: String
        /// Absent on the base side = the header was added.
        public var base: [String]?
        /// Absent on the compared side = the header was removed.
        public var compared: [String]?

        public init(name: String, base: [String]?, compared: [String]?) {
            self.name = name
            self.base = base
            self.compared = compared
        }

        public var isAddition: Bool { base == nil }
        public var isRemoval: Bool { compared == nil }
    }

    /// How the two bodies differ. `nil` (no `BodyComparison` at all) means they are
    /// byte-identical *and* both were captured whole; the cases below say how much
    /// detail was worth computing.
    public struct BodyComparison: Equatable, Sendable {
        /// Why a line diff wasn't computed. Each carries the limit it hit, because
        /// "too big" without the threshold is not something a reader can act on.
        public enum SkipReason: Equatable, Sendable {
            /// More lines than `maxDiffLines` on at least one side.
            case tooManyLines(limit: Int)
            /// A single line longer than `maxDiffLineBytes`. This is the minified
            /// payload: one line, well under the line cap, and a "line diff" of it
            /// is the whole body twice over.
            case lineTooLong(limit: Int)
            /// More bytes than `maxDiffBytes` on at least one side.
            case tooManyBytes(limit: Int)

            /// The one sentence both surfaces show. Kept here so the JSON and the
            /// Inspector can't word it differently.
            public var explanation: String {
                switch self {
                case let .tooManyLines(limit): "body exceeds \(limit) lines"
                case let .lineTooLong(limit): "a single line exceeds \(limit) bytes"
                case let .tooManyBytes(limit): "body exceeds \(limit) bytes"
                }
            }
        }

        public enum Detail: Equatable, Sendable {
            /// Line-level diff of two UTF-8 bodies.
            case lines(added: [String], removed: [String])
            /// At least one side isn't UTF-8 — sizes only.
            case binary
            /// Not line-diffed; sizes, line counts and the reason only.
            case tooLarge(baseLines: Int, comparedLines: Int, reason: SkipReason)
            /// The *captured* bytes are identical, but at least one side is a
            /// capture-capped prefix, so the bytes past the cap were never
            /// compared. Neither "same" nor a known difference — the wire sizes
            /// below are what there is to go on.
            case tailNotCaptured
        }

        /// Bytes Loom recorded — a prefix when the corresponding `…WireBytes` is set.
        public var baseBytes: Int
        public var comparedBytes: Int
        /// Bytes that actually crossed the wire, set only when `baseBytes` is a
        /// capped prefix of them (`CapturedRequest/Response.fullBodyBytes`).
        public var baseWireBytes: Int?
        public var comparedWireBytes: Int?
        public var detail: Detail

        /// Either side is a prefix — so every verdict here covers the prefix only.
        public var isTruncated: Bool { baseWireBytes != nil || comparedWireBytes != nil }

        public init(
            baseBytes: Int,
            comparedBytes: Int,
            baseWireBytes: Int? = nil,
            comparedWireBytes: Int? = nil,
            detail: Detail
        ) {
            self.baseBytes = baseBytes
            self.comparedBytes = comparedBytes
            self.baseWireBytes = baseWireBytes
            self.comparedWireBytes = comparedWireBytes
            self.detail = detail
        }
    }

    /// What differs about two flows' WebSocket frame logs.
    ///
    /// It exists so `isIdentical` can't lie: without it two WebSocket flows whose
    /// frames share nothing but the HTTP upgrade compared "identical", and the
    /// Inspector said so in as many words.
    ///
    /// Frames are compared on **content** — direction, kind, payload, FIN — never
    /// on `id` or `timestamp`, which differ between any two captures of the same
    /// conversation and would make every pair differ at frame 0.
    public struct WebSocketComparison: Equatable, Sendable {
        /// Set when one side is a WebSocket and the other isn't.
        public var presence: ValueChange<Bool>?
        public var messageCount: ValueChange<Int>?
        /// Index of the first frame whose content differs, when both sides have
        /// frames. A whole-log diff is deliberately not attempted: frame logs are
        /// unbounded and the first divergence is the actionable part.
        public var firstDifferingMessage: Int?
        /// Frames the capture cap dropped, when the two sides dropped differently.
        public var droppedMessages: ValueChange<Int>?
        /// Frame capture giving up mid-connection, when it happened on one side.
        public var captureError: ValueChange<String>?

        public init(
            presence: ValueChange<Bool>? = nil,
            messageCount: ValueChange<Int>? = nil,
            firstDifferingMessage: Int? = nil,
            droppedMessages: ValueChange<Int>? = nil,
            captureError: ValueChange<String>? = nil
        ) {
            self.presence = presence
            self.messageCount = messageCount
            self.firstDifferingMessage = firstDifferingMessage
            self.droppedMessages = droppedMessages
            self.captureError = captureError
        }

        public var isEmpty: Bool {
            presence == nil && messageCount == nil && firstDifferingMessage == nil
                && droppedMessages == nil && captureError == nil
        }
    }

    /// The parts every message has: headers and a body.
    public struct MessageComparison: Equatable, Sendable {
        /// Request-only: the method.
        public var method: ValueChange<String>?
        /// Request-only: the URL.
        public var url: ValueChange<String>?
        public var headers: [HeaderChange]
        public var body: BodyComparison?

        public init(
            method: ValueChange<String>? = nil,
            url: ValueChange<String>? = nil,
            headers: [HeaderChange] = [],
            body: BodyComparison? = nil
        ) {
            self.method = method
            self.url = url
            self.headers = headers
            self.body = body
        }

        public var isEmpty: Bool {
            method == nil && url == nil && headers.isEmpty && body == nil
        }
    }

    public struct ResponseComparison: Equatable, Sendable {
        /// Set when one side answered and the other didn't — a missing response is
        /// the difference, and reporting header/body diffs against nothing would be
        /// noise.
        public var presence: ValueChange<Bool>?
        public var status: ValueChange<Int>?
        public var httpVersion: ValueChange<String>?
        public var headers: [HeaderChange]
        public var body: BodyComparison?

        public init(
            presence: ValueChange<Bool>? = nil,
            status: ValueChange<Int>? = nil,
            httpVersion: ValueChange<String>? = nil,
            headers: [HeaderChange] = [],
            body: BodyComparison? = nil
        ) {
            self.presence = presence
            self.status = status
            self.httpVersion = httpVersion
            self.headers = headers
            self.body = body
        }

        public var isEmpty: Bool {
            presence == nil && status == nil && httpVersion == nil && headers.isEmpty && body == nil
        }
    }
}

// MARK: - Computing it

public extension FlowComparison {
    /// Cap the fine-grained line diff so a huge body can't produce an O(n·m)
    /// blow-up, flood an agent's context, or stall the Inspector.
    static let maxDiffLines = 400

    /// Longest single line that gets line-diffed. The line cap alone does not bound
    /// anything: a minified JSON body is **one** line, passes `maxDiffLines`
    /// trivially, and then its "line diff" is the entire payload as one added line
    /// plus the entire other payload as one removed line — megabytes into an
    /// agent's context and into a `Text` view.
    static let maxDiffLineBytes = 4096

    /// Whole-body ceiling, checked before splitting so a huge payload isn't even
    /// broken into lines. `maxDiffLines * maxDiffLineBytes` is the worst case a
    /// line diff can emit; this keeps the common case far under it.
    static let maxDiffBytes = 128 * 1024

    /// Compare `compared` against `base`. Only genuine differences are populated.
    static func compare(base: Flow, compared: Flow) -> FlowComparison {
        FlowComparison(
            baseID: base.id,
            comparedID: compared.id,
            request: compareRequests(base.request, compared.request),
            response: compareResponses(base.response, compared.response),
            webSocket: compareWebSockets(base, compared),
            error: change(base.error, compared.error)
        )
    }

    private static func compareRequests(_ base: CapturedRequest, _ compared: CapturedRequest) -> MessageComparison {
        MessageComparison(
            method: change(base.method, compared.method),
            url: change(base.url, compared.url),
            headers: compareHeaders(base.headers, compared.headers),
            body: compareBodies(
                base.body, compared.body,
                baseWireBytes: base.fullBodyBytes, comparedWireBytes: compared.fullBodyBytes
            )
        )
    }

    private static func compareResponses(_ base: CapturedResponse?, _ compared: CapturedResponse?) -> ResponseComparison {
        switch (base, compared) {
        case (nil, nil):
            return ResponseComparison()
        case let (base?, compared?):
            return ResponseComparison(
                status: change(base.statusCode, compared.statusCode),
                httpVersion: change(base.httpVersion, compared.httpVersion),
                headers: compareHeaders(base.headers, compared.headers),
                body: compareBodies(
                    base.body, compared.body,
                    baseWireBytes: base.fullBodyBytes, comparedWireBytes: compared.fullBodyBytes
                )
            )
        default:
            return ResponseComparison(presence: ValueChange(base: base != nil, compared: compared != nil))
        }
    }

    /// Frame-log differences. Nothing is reported for two non-WebSocket flows,
    /// which is every ordinary comparison.
    static func compareWebSockets(_ base: Flow, _ compared: Flow) -> WebSocketComparison {
        switch (base.webSocketMessages, compared.webSocketMessages) {
        case (nil, nil):
            return WebSocketComparison()
        case let (baseFrames?, comparedFrames?):
            return WebSocketComparison(
                messageCount: change(baseFrames.count, comparedFrames.count),
                firstDifferingMessage: firstDifference(baseFrames, comparedFrames),
                droppedMessages: change(base.webSocketDroppedMessages, compared.webSocketDroppedMessages),
                captureError: change(base.webSocketCaptureError, compared.webSocketCaptureError)
            )
        default:
            return WebSocketComparison(
                presence: ValueChange(
                    base: base.webSocketMessages != nil,
                    compared: compared.webSocketMessages != nil
                )
            )
        }
    }

    /// Index of the first frame differing in content. `id` and `timestamp` are
    /// excluded on purpose — see `WebSocketComparison`.
    private static func firstDifference(_ base: [WebSocketMessage], _ compared: [WebSocketMessage]) -> Int? {
        func differs(_ a: WebSocketMessage, _ b: WebSocketMessage) -> Bool {
            a.direction != b.direction || a.kind != b.kind || a.isFinal != b.isFinal || a.payload != b.payload
        }
        for index in 0 ..< min(base.count, compared.count) where differs(base[index], compared[index]) {
            return index
        }
        return nil
    }

    /// `nil` when the two values are equal.
    private static func change<Value: Equatable & Sendable>(_ base: Value?, _ compared: Value?) -> ValueChange<Value>? {
        base == compared ? nil : ValueChange(base: base, compared: compared)
    }

    /// Group two ordered header lists by case-insensitive name and report the
    /// differences. Base order first, then compared-only names, so the output is
    /// stable across runs.
    static func compareHeaders(_ base: [HeaderPair], _ compared: [HeaderPair]) -> [HeaderChange] {
        // Preserve first-seen display casing while keying case-insensitively.
        func grouped(_ headers: [HeaderPair]) -> (order: [String], byKey: [String: (name: String, values: [String])]) {
            var order: [String] = []
            var byKey: [String: (name: String, values: [String])] = [:]
            for header in headers {
                let key = header.name.lowercased()
                if byKey[key] == nil {
                    byKey[key] = (header.name, [])
                    order.append(key)
                }
                byKey[key]?.values.append(header.value)
            }
            return (order, byKey)
        }

        let b = grouped(base)
        let c = grouped(compared)

        var changes: [HeaderChange] = []
        var seen = Set<String>()
        for key in b.order + c.order where seen.insert(key).inserted {
            switch (b.byKey[key], c.byKey[key]) {
            case let (nil, comp?):
                changes.append(HeaderChange(name: comp.name, base: nil, compared: comp.values))
            case let (base?, nil):
                changes.append(HeaderChange(name: base.name, base: base.values, compared: nil))
            case let (base?, comp?) where base.values != comp.values:
                changes.append(HeaderChange(name: comp.name, base: base.values, compared: comp.values))
            default:
                break // identical
            }
        }
        return changes
    }

    /// `nil` when the bodies are byte-identical **and** both were captured whole.
    /// Text bodies of manageable size get a line diff; anything else reports sizes
    /// and says why.
    ///
    /// `baseWireBytes` / `comparedWireBytes` are `fullBodyBytes` — set when that
    /// side's `Data` is a capture-capped prefix. They are not decoration: two
    /// bodies capped at the same byte count have identical prefixes whatever their
    /// tails did, so without them a truncated pair reports a confident `nil`
    /// ("no difference") for a comparison that never saw most of the payload.
    static func compareBodies(
        _ base: Data?,
        _ compared: Data?,
        baseWireBytes: Int? = nil,
        comparedWireBytes: Int? = nil
    ) -> BodyComparison? {
        let baseData = base ?? Data()
        let comparedData = compared ?? Data()

        func comparison(_ detail: BodyComparison.Detail) -> BodyComparison {
            BodyComparison(
                baseBytes: baseData.count,
                comparedBytes: comparedData.count,
                baseWireBytes: baseWireBytes,
                comparedWireBytes: comparedWireBytes,
                detail: detail
            )
        }

        guard baseData != comparedData else {
            // Recorded bytes match. That settles it only if both sides are whole;
            // otherwise the prefixes match and the tails are simply unknown.
            guard baseWireBytes != nil || comparedWireBytes != nil else { return nil }
            return comparison(.tailNotCaptured)
        }

        guard let baseText = String(data: baseData, encoding: .utf8),
              let comparedText = String(data: comparedData, encoding: .utf8) else {
            return comparison(.binary)
        }

        // Before splitting: a multi-megabyte body should not be broken into lines
        // just to find out it was too big to diff. Counting newlines allocates
        // nothing.
        guard baseData.count <= maxDiffBytes, comparedData.count <= maxDiffBytes else {
            return comparison(.tooLarge(
                baseLines: lineCount(baseText),
                comparedLines: lineCount(comparedText),
                reason: .tooManyBytes(limit: maxDiffBytes)
            ))
        }

        let baseLines = baseText.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let comparedLines = comparedText.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

        guard baseLines.count <= maxDiffLines, comparedLines.count <= maxDiffLines else {
            return comparison(.tooLarge(
                baseLines: baseLines.count,
                comparedLines: comparedLines.count,
                reason: .tooManyLines(limit: maxDiffLines)
            ))
        }

        // The minified case: few lines, each enormous. A line diff here is the two
        // whole bodies echoed back, which is exactly what the caps exist to avoid.
        let longestLine = (baseLines + comparedLines).lazy.map(\.utf8.count).max() ?? 0
        guard longestLine <= maxDiffLineBytes else {
            return comparison(.tooLarge(
                baseLines: baseLines.count,
                comparedLines: comparedLines.count,
                reason: .lineTooLong(limit: maxDiffLineBytes)
            ))
        }

        let (added, removed) = lineDiff(baseLines, comparedLines)
        return comparison(.lines(added: added, removed: removed))
    }

    /// Lines as `split(separator: "\n", omittingEmptySubsequences: false)` would
    /// count them, without building any of them.
    private static func lineCount(_ text: String) -> Int {
        text.utf8.reduce(1) { $1 == UInt8(ascii: "\n") ? $0 + 1 : $0 }
    }

    /// Longest-common-subsequence line diff: `removed` are lines in `a` not on the
    /// common subsequence, `added` are lines in `b` not on it.
    ///
    /// Lines are split on `\n` only, so a CRLF body keeps a trailing `\r` on every
    /// line. That is deliberate: a line whose bytes differ by a CR *is* a line that
    /// differs, and quietly normalizing it would report "no line changed" for two
    /// bodies whose sizes visibly disagree.
    static func lineDiff(_ a: [String], _ b: [String]) -> (added: [String], removed: [String]) {
        let n = a.count, m = b.count
        // DP table of LCS lengths.
        var lcs = [[Int]](repeating: [Int](repeating: 0, count: m + 1), count: n + 1)
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                lcs[i][j] = a[i] == b[j] ? lcs[i + 1][j + 1] + 1 : max(lcs[i + 1][j], lcs[i][j + 1])
            }
        }
        var added: [String] = [], removed: [String] = []
        var i = 0, j = 0
        while i < n, j < m {
            if a[i] == b[j] {
                i += 1; j += 1
            } else if lcs[i + 1][j] >= lcs[i][j + 1] {
                removed.append(a[i]); i += 1
            } else {
                added.append(b[j]); j += 1
            }
        }
        while i < n { removed.append(a[i]); i += 1 }
        while j < m { added.append(b[j]); j += 1 }
        return (added, removed)
    }
}
