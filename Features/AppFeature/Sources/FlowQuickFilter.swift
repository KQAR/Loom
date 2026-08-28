import Foundation
import LoomSharedModels

/// The four axes the quick-filter chips narrow on.
///
/// A facet, not a `FlowCategory.Dimension`: these are **window-local**. The sidebar's
/// dimensions are pushed into `FlowQuery` where they can be (`FlowSearch.engineQuery`)
/// so the engine hydrates fewer bodies; a chip is never pushed down, because every
/// fact it reads — the scheme, the client's HTTP version, the response's
/// `Content-Type`, the status class — is already on the body-free row this window
/// holds. Answering here costs a predicate over rows already in memory; asking the
/// engine would cost a round trip to learn what the row already says.
public enum QuickFilterFacet: String, CaseIterable, Sendable {
    case transport
    case httpVersion
    case content
    case status

    /// The group heading in the picker.
    public var label: String {
        switch self {
        case .transport: "Protocol"
        case .httpVersion: "Version"
        case .content: "Content"
        case .status: "Status"
        }
    }
}

/// How the exchange travelled, as the row can tell it: the request URL's scheme,
/// with a WebSocket upgrade winning over the `http(s)` it was negotiated on — the
/// same reading the table's Protocol column shows (`MainView.protocolLabel`), so a
/// chip cannot select rows that read as something else.
public enum QuickTransport: String, CaseIterable, Sendable {
    case http
    case https
    case webSocket

    public var label: String {
        switch self {
        case .http: "HTTP"
        case .https: "HTTPS"
        case .webSocket: "WS"
        }
    }
}

/// The version the **client** negotiated (`CapturedRequest.httpVersion`), never the
/// response's.
///
/// The two are different facts and routinely disagree — the response's is Loom's
/// upstream hop — so filtering on the response would answer "which protocol did Loom
/// speak upstream", which is not what a person clicking `HTTP/2` is asking.
public enum QuickHTTPVersion: String, CaseIterable, Sendable {
    case http1
    case http2

    public var label: String {
        switch self {
        case .http1: "HTTP/1"
        case .http2: "HTTP/2"
        }
    }
}

/// What the response body is, read off its `Content-Type`.
///
/// `binary` means *typed and not one of the above* (`application/octet-stream`,
/// protobuf, a font, a PDF) — it is **not** a bucket for rows Loom couldn't classify.
/// A row with no response yet, or a response with no `Content-Type`, matches no
/// content chip at all: absent means unmeasured, never "no", which is the same rule
/// `FlowTransport` holds. The alternative — folding the unknowns into `binary` —
/// would make one chip answer two questions and make "show me the binary payloads"
/// return every pending exchange in the window.
public enum QuickContentKind: String, CaseIterable, Sendable {
    case json
    case xml
    case html
    case javascript
    case text
    case image
    case media
    case binary

    public var label: String {
        switch self {
        case .json: "JSON"
        case .xml: "XML"
        case .html: "HTML"
        case .javascript: "JS"
        case .text: "Text"
        case .image: "Image"
        case .media: "Media"
        case .binary: "Binary"
        }
    }
}

/// The response's status class. A row that never got a status — pending, failed
/// before the head, a tunnel record — matches none of these, for the reason
/// `QuickContentKind` documents.
public enum QuickStatusClass: Int, CaseIterable, Sendable {
    case informational = 1
    case success = 2
    case redirection = 3
    case clientError = 4
    case serverError = 5

    public var label: String { "\(rawValue)xx" }
}

/// One chip. A single addressable identity across all four facets, so the view binds
/// to one `Set` and the reducer takes one action — the alternative is four parallel
/// sets, four actions and four places to forget.
public enum QuickFilterChip: Hashable, Sendable {
    case transport(QuickTransport)
    case httpVersion(QuickHTTPVersion)
    case content(QuickContentKind)
    case status(QuickStatusClass)

    /// Every chip, in the order the picker draws them.
    ///
    /// Hand-written rather than `CaseIterable`: the macro cannot synthesize it for an
    /// enum with associated values, and the order here is the display order.
    public static let all: [QuickFilterChip] =
        QuickTransport.allCases.map(Self.transport)
            + QuickHTTPVersion.allCases.map(Self.httpVersion)
            + QuickContentKind.allCases.map(Self.content)
            + QuickStatusClass.allCases.map(Self.status)

    public var facet: QuickFilterFacet {
        switch self {
        case .transport: .transport
        case .httpVersion: .httpVersion
        case .content: .content
        case .status: .status
        }
    }

    public var label: String {
        switch self {
        case let .transport(value): value.label
        case let .httpVersion(value): value.label
        case let .content(value): value.label
        case let .status(value): value.label
        }
    }
}

/// The request list's floating quick filters: a set of chips over four facets.
///
/// ## What a set of these means
///
/// **OR within a facet, AND across** — the same rule `FlowCategory.Dimension` holds
/// for the sidebar, and deliberately the same, because the two compose: the sidebar
/// narrows *whose* traffic, the find bar narrows *which exchange*, and these narrow
/// *what shape* it is. All three are ANDed in `CaptureFeature.State.computeVisibleFlows`.
///
/// ## Why it never reaches the engine
///
/// This filters **the window only**. `FlowSearch.engineQuery` pushes what it can
/// down because a body search would otherwise hydrate every payload off disk; a chip
/// reads fields the body-free row already carries, so there is nothing to save and a
/// pushdown would add a way for the two answers to disagree. The consequence is
/// stated rather than hidden: a chip narrows the rows this window holds, and flows
/// that aged out of it are as absent as they were before.
public struct FlowQuickFilter: Equatable, Sendable {
    /// Selected chips. Private setter so `toggle` / `clear` are the only writers —
    /// a raw assignment is how a set that means nothing (every chip in a facet, which
    /// is the same as none) gets in.
    public private(set) var chips: Set<QuickFilterChip> = []

    public init() {}

    public init(_ chips: Set<QuickFilterChip>) {
        self.chips = chips
    }

    /// Whether anything is being narrowed. False for the empty set, which is what
    /// makes the projection's cheap-rebuild test correct.
    public var isActive: Bool { !chips.isEmpty }

    public func contains(_ chip: QuickFilterChip) -> Bool { chips.contains(chip) }

    /// Selected chips in display order, for the floating bar's inline summary.
    public var ordered: [QuickFilterChip] { QuickFilterChip.all.filter(chips.contains) }

    public mutating func toggle(_ chip: QuickFilterChip) {
        if chips.contains(chip) { chips.remove(chip) } else { chips.insert(chip) }
    }

    public mutating func clear() { chips.removeAll() }

    /// How many chips one facet has selected — the picker's group badge.
    public func count(in facet: QuickFilterFacet) -> Int {
        chips.count(where: { $0.facet == facet })
    }

    /// The row predicate, with the per-facet buckets hoisted out of the loop.
    ///
    /// Built **once per projection rebuild**, never per row, for the reason
    /// `FlowSearch.predicate` measured: this runs over the whole window (up to
    /// `FlowLimits.windowRows`) on every capture batch while a chip is up, so
    /// re-deriving four sets per row would put the selection's cost on every flow.
    /// Classification itself is lazy in the same spirit — the `Content-Type` scan
    /// only happens when a content chip is actually selected.
    public func predicate() -> (Flow) -> Bool {
        guard isActive else { return { _ in true } }
        var transports: Set<QuickTransport> = []
        var versions: Set<QuickHTTPVersion> = []
        var contents: Set<QuickContentKind> = []
        var statuses: Set<QuickStatusClass> = []
        for chip in chips {
            switch chip {
            case let .transport(value): transports.insert(value)
            case let .httpVersion(value): versions.insert(value)
            case let .content(value): contents.insert(value)
            case let .status(value): statuses.insert(value)
            }
        }
        return { flow in
            if !transports.isEmpty {
                guard let value = Self.transport(of: flow), transports.contains(value) else { return false }
            }
            if !versions.isEmpty {
                guard let value = Self.httpVersion(of: flow), versions.contains(value) else { return false }
            }
            if !statuses.isEmpty {
                guard let value = Self.statusClass(of: flow), statuses.contains(value) else { return false }
            }
            if !contents.isEmpty {
                guard let value = Self.contentKind(of: flow), contents.contains(value) else { return false }
            }
            return true
        }
    }

    // MARK: Classification

    /// The scheme, WebSocket winning over what it upgraded from.
    ///
    /// **It has to agree with the table's Protocol column** (`MainView.protocolLabel`),
    /// or a chip selects rows that read as something else — which is why a `ws://` URL
    /// is a WebSocket row here even before a frame has been relayed: `WS` is what the
    /// column already prints for it. An intercepted upgrade is the same rule from the
    /// other side — it is captured on the `https://` URL it was negotiated on, and
    /// `isWebSocket` is what tells the two apart.
    ///
    /// A prefix test on the URL string rather than a `URL`/`URLComponents` parse: this
    /// is a per-row read on the live path, and building a `URLComponents` per row is
    /// the cost `Flow.host` documents going out of its way to avoid.
    ///
    /// A record with no scheme at all — a legacy `CONNECT` row, whose URL is
    /// `host:port` — is **nil rather than guessed as https**. A tunnel is not
    /// necessarily TLS (an `ALL_PROXY` client tunnelling SSH is the measured case),
    /// so answering "HTTPS" there would put non-HTTP connections behind an HTTPS chip.
    static func transport(of flow: Flow) -> QuickTransport? {
        let url = flow.request.url
        if flow.isWebSocket { return .webSocket }
        if url.hasPrefix("ws://") || url.hasPrefix("wss://") { return .webSocket }
        if url.hasPrefix("https://") { return .https }
        if url.hasPrefix("http://") { return .http }
        return nil
    }

    /// The client leg's version. `HTTP/1.0` and `HTTP/1.1` are one chip: the
    /// distinction changes nothing about how the exchange is read, and two chips that
    /// are almost always the same one are two chips nobody clicks.
    static func httpVersion(of flow: Flow) -> QuickHTTPVersion? {
        guard let version = flow.request.httpVersion else { return nil }
        if version.hasPrefix("HTTP/1") { return .http1 }
        if version.hasPrefix("HTTP/2") { return .http2 }
        return nil
    }

    static func statusClass(of flow: Flow) -> QuickStatusClass? {
        guard let code = flow.statusCode else { return nil }
        return QuickStatusClass(rawValue: code / 100)
    }

    /// The response's `Content-Type`, bucketed.
    ///
    /// Order matters and is not alphabetical, in two places that were each wrong the
    /// obvious way round first:
    ///
    /// - **`image/` and `audio/`/`video/` are tested before the structured-suffix
    ///   tests**, because `image/svg+xml` is an image whose type ends in `+xml`, and
    ///   someone clicking `Image` is asking for the pictures.
    /// - **JSON, then HTML, then XML, then the `text/` catch-all**: `application/ld+json`
    ///   is JSON, `application/xhtml+xml` is HTML, and `text/xml` is XML rather than
    ///   text.
    ///
    /// Matched over the UTF-8 view with an ASCII case fold and **no allocation**. This
    /// runs for every row of the window on every rebuild while a content chip is up, and
    /// `prefix(while:).trimmingCharacters(in:).lowercased()` was three small allocations
    /// per row to answer one question — the same shape as the per-row needle preparation
    /// `FlowSearch.predicate` exists to hoist out.
    static func contentKind(of flow: Flow) -> QuickContentKind? {
        guard let response = flow.response, let raw = contentTypeValue(response.headers) else { return nil }
        // Only the media type: a `; charset=…` parameter can carry anything, and a
        // substring match against it is how `text/plain; charset=x-json` becomes JSON.
        let type = mediaType(of: raw)
        guard !type.isEmpty else { return nil }
        if hasASCIIPrefix(type, "image/") { return .image }
        if hasASCIIPrefix(type, "audio/") || hasASCIIPrefix(type, "video/") { return .media }
        if containsASCII(type, "json") { return .json }
        if containsASCII(type, "html") { return .html }
        if containsASCII(type, "javascript") || containsASCII(type, "ecmascript") { return .javascript }
        if containsASCII(type, "xml") { return .xml }
        if hasASCIIPrefix(type, "text/") { return .text }
        if hasASCIIPrefix(type, "application/x-www-form-urlencoded") { return .text }
        return .binary
    }

    /// The media type alone — everything before the first `;`, without the whitespace
    /// either side of it. A `Substring`, so nothing is copied.
    static func mediaType(of value: String) -> Substring {
        var end = value.firstIndex(of: ";") ?? value.endIndex
        var start = value.startIndex
        while start < end, value[start] == " " || value[start] == "\t" {
            start = value.index(after: start)
        }
        while end > start {
            let previous = value.index(before: end)
            guard value[previous] == " " || value[previous] == "\t" else { break }
            end = previous
        }
        return value[start ..< end]
    }

    /// First `Content-Type` in header order, matched case-insensitively without
    /// allocating.
    ///
    /// `HeaderPair.name` is whatever the wire said, so the comparison has to fold
    /// case — but `lowercased()` here would allocate a String **per header per row**,
    /// which at a full window and ~20 headers a flow is hundreds of thousands of
    /// allocations to answer one question. An ASCII fold over the UTF-8 view answers
    /// it with none.
    static func contentTypeValue(_ headers: [HeaderPair]) -> String? {
        for pair in headers where matchesASCIICaseInsensitively(pair.name, "content-type") {
            return pair.value
        }
        return nil
    }

    /// `haystack` starts with `lowercaseNeedle`, folding ASCII case.
    static func hasASCIIPrefix(_ haystack: Substring, _ lowercaseNeedle: String) -> Bool {
        var lhs = haystack.utf8.makeIterator()
        for expected in lowercaseNeedle.utf8 {
            guard let byte = lhs.next(), asciiLowercased(byte) == expected else { return false }
        }
        return true
    }

    /// `haystack` contains `lowercaseNeedle`, folding ASCII case.
    ///
    /// The naive scan, deliberately: the needles here are 3–10 bytes and a media type
    /// is a couple of dozen, so anything cleverer costs more to set up than it saves —
    /// and `range(of:options:.caseInsensitive)` is the one thing it must not be, that
    /// being the NSString bridge `FlowSearch.predicate` measured at 84 ms a keystroke.
    static func containsASCII(_ haystack: Substring, _ lowercaseNeedle: String) -> Bool {
        let bytes = haystack.utf8
        guard !lowercaseNeedle.isEmpty, bytes.count >= lowercaseNeedle.utf8.count else { return false }
        var start = bytes.startIndex
        let limit = bytes.index(bytes.endIndex, offsetBy: -lowercaseNeedle.utf8.count)
        while start <= limit {
            var index = start
            var matched = true
            for expected in lowercaseNeedle.utf8 {
                if asciiLowercased(bytes[index]) != expected { matched = false; break }
                index = bytes.index(after: index)
            }
            if matched { return true }
            start = bytes.index(after: start)
        }
        return false
    }

    /// 0x41...0x5A is A–Z; +0x20 is its lowercase. Non-ASCII bytes pass through, which
    /// is the right answer for header names and media types — both ASCII by RFC.
    private static func asciiLowercased(_ byte: UInt8) -> UInt8 {
        (byte >= 0x41 && byte <= 0x5A) ? byte + 0x20 : byte
    }

    /// `name == lowercaseTarget`, folding ASCII case only.
    private static func matchesASCIICaseInsensitively(_ name: String, _ lowercaseTarget: String) -> Bool {
        let name = name.utf8
        let target = lowercaseTarget.utf8
        guard name.count == target.count else { return false }
        var lhs = name.makeIterator()
        var rhs = target.makeIterator()
        while let a = lhs.next(), let b = rhs.next() {
            let folded = asciiLowercased(a)
            if folded != b { return false }
        }
        return true
    }
}
