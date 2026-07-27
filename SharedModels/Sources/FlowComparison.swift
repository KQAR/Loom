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
public struct FlowComparison: Equatable, Sendable {
    public var baseID: UUID
    public var comparedID: UUID
    public var request: MessageComparison
    public var response: ResponseComparison
    /// Transport-level error text, when one side failed and the other didn't (or
    /// they failed differently).
    public var error: ValueChange<String>?

    /// Nothing differs anywhere.
    public var isIdentical: Bool {
        request.isEmpty && response.isEmpty && error == nil
    }

    public init(
        baseID: UUID,
        comparedID: UUID,
        request: MessageComparison,
        response: ResponseComparison,
        error: ValueChange<String>? = nil
    ) {
        self.baseID = baseID
        self.comparedID = comparedID
        self.request = request
        self.response = response
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
    /// byte-identical; the cases below say how much detail was worth computing.
    public struct BodyComparison: Equatable, Sendable {
        public enum Detail: Equatable, Sendable {
            /// Line-level diff of two UTF-8 bodies.
            case lines(added: [String], removed: [String])
            /// At least one side isn't UTF-8 — sizes only.
            case binary
            /// Too many lines to diff pairwise; sizes and line counts only.
            case tooLarge(baseLines: Int, comparedLines: Int, limit: Int)
        }

        public var baseBytes: Int
        public var comparedBytes: Int
        public var detail: Detail

        public init(baseBytes: Int, comparedBytes: Int, detail: Detail) {
            self.baseBytes = baseBytes
            self.comparedBytes = comparedBytes
            self.detail = detail
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

    /// Compare `compared` against `base`. Only genuine differences are populated.
    static func compare(base: Flow, compared: Flow) -> FlowComparison {
        FlowComparison(
            baseID: base.id,
            comparedID: compared.id,
            request: compareRequests(base.request, compared.request),
            response: compareResponses(base.response, compared.response),
            error: change(base.error, compared.error)
        )
    }

    private static func compareRequests(_ base: CapturedRequest, _ compared: CapturedRequest) -> MessageComparison {
        MessageComparison(
            method: change(base.method, compared.method),
            url: change(base.url, compared.url),
            headers: compareHeaders(base.headers, compared.headers),
            body: compareBodies(base.body, compared.body)
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
                body: compareBodies(base.body, compared.body)
            )
        default:
            return ResponseComparison(presence: ValueChange(base: base != nil, compared: compared != nil))
        }
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

    /// `nil` when the bodies are byte-identical. Text bodies of manageable size get
    /// a line diff; anything else reports sizes and says why.
    static func compareBodies(_ base: Data?, _ compared: Data?) -> BodyComparison? {
        let baseData = base ?? Data()
        let comparedData = compared ?? Data()
        guard baseData != comparedData else { return nil }

        guard let baseText = String(data: baseData, encoding: .utf8),
              let comparedText = String(data: comparedData, encoding: .utf8) else {
            return BodyComparison(baseBytes: baseData.count, comparedBytes: comparedData.count, detail: .binary)
        }

        let baseLines = baseText.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let comparedLines = comparedText.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

        guard baseLines.count <= maxDiffLines, comparedLines.count <= maxDiffLines else {
            return BodyComparison(
                baseBytes: baseData.count,
                comparedBytes: comparedData.count,
                detail: .tooLarge(baseLines: baseLines.count, comparedLines: comparedLines.count, limit: maxDiffLines)
            )
        }

        let (added, removed) = lineDiff(baseLines, comparedLines)
        return BodyComparison(
            baseBytes: baseData.count,
            comparedBytes: comparedData.count,
            detail: .lines(added: added, removed: removed)
        )
    }

    /// Longest-common-subsequence line diff: `removed` are lines in `a` not on the
    /// common subsequence, `added` are lines in `b` not on it.
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
