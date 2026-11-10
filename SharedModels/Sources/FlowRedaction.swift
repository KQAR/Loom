import Foundation

/// Strips credentials out of flows before they leave the machine — the difference
/// between a HAR you can attach to a bug report and one you can't.
///
/// A capture is full of secrets by construction: `Authorization` bearer tokens,
/// session cookies, API keys in query strings, whole request bodies with personal
/// data. Loom's HAR export is the one place captured traffic is *meant* to leave the
/// machine, so it needs a mode that keeps the shape of the exchange (who called what,
/// what came back, how long it took) while removing the parts nobody should paste
/// into a ticket.
///
/// Redaction **replaces rather than removes**: a redacted header is still present
/// with the value `<redacted>`, and a dropped body still reports its size. A reader
/// (human or agent) must be able to tell "there was a token here" from "there was no
/// token" — silently deleting the header would turn a redacted export into a
/// misleading one, and would also change what a replay of it does.
public struct FlowRedaction: Equatable, Sendable {
    public static let placeholder = "<redacted>"

    /// Headers whose values are secrets in practically every API. Matched
    /// case-insensitively, on the whole name.
    public static let defaultHeaderNames = [
        "authorization",
        "proxy-authorization",
        "cookie",
        "set-cookie",
        "x-api-key",
        "x-auth-token",
        "x-csrf-token",
        "x-session-token",
        "api-key",
    ]

    /// Query parameters that routinely carry credentials.
    public static let defaultQueryKeys = [
        "access_token",
        "api_key",
        "apikey",
        "auth",
        "id_token",
        "key",
        "password",
        "refresh_token",
        "sig",
        "signature",
        "token",
    ]

    public var headerNames: [String]
    public var queryKeys: [String]
    /// Drop request and response bodies entirely (their sizes are kept), and blank
    /// WebSocket frame payloads the same way. The blunt instrument for "I can't
    /// audit every payload, so send none of them".
    ///
    /// Frames count as bodies: a subscribe message carrying a token is the same
    /// leak as a login POST, and a socket transcript was previously copied into a
    /// "redacted" export untouched.
    public var dropBodies: Bool

    public init(
        headerNames: [String] = FlowRedaction.defaultHeaderNames,
        queryKeys: [String] = FlowRedaction.defaultQueryKeys,
        dropBodies: Bool = false
    ) {
        self.headerNames = headerNames
        self.queryKeys = queryKeys
        self.dropBodies = dropBodies
    }

    /// Redact one flow. Timing, status, sizes, rule hits and attribution all survive
    /// — those are what makes an exported exchange diagnosable.
    public func apply(to flow: Flow) -> Flow {
        var copy = flow
        copy.request.headers = redact(headers: flow.request.headers)
        copy.request.url = redact(url: flow.request.url)
        if dropBodies, let body = copy.request.body {
            // Preserve the size before dropping the bytes: `fullBodyBytes` is how the
            // rest of Loom already says "the payload was bigger than what you see".
            copy.request.fullBodyBytes = copy.request.fullBodyBytes ?? body.count
            copy.request.body = nil
        }
        copy.outcome = redact(outcome: flow.outcome)
        if dropBodies, let messages = flow.webSocketMessages {
            copy.webSocketMessages = messages.map(redact(message:))
        }
        return copy
    }

    public func apply(to flows: [Flow]) -> [Flow] {
        flows.map(apply(to:))
    }

    /// What an agent reads over MCP while `ProxyStatus.redactsAgentReads` is on:
    /// the default headers and query keys, **bodies kept**. Dropping bodies would
    /// take the payload out of every debugging loop, which is what an agent is
    /// reading the capture *for*; the credential that leaks by default is the one
    /// on every request, in the header.
    public static let agentReads = FlowRedaction()

    /// A held exchange, by the same rules as a flow.
    public func apply(to pending: PendingBreakpoint) -> PendingBreakpoint {
        var copy = pending
        copy.url = redact(url: pending.url)
        copy.requestHeaders = redact(headers: pending.requestHeaders)
        copy.responseHeaders = pending.responseHeaders.map(redact(headers:))
        if dropBodies {
            copy.requestBody = nil
            copy.responseBody = nil
        }
        return copy
    }

    /// A comparison, redacted **after** it was computed over the originals.
    ///
    /// Redacting the two flows first and comparing those would make a rotated token
    /// read as identical — `<redacted>` equals `<redacted>` — and `diff_flows`
    /// answering "no difference" for the one header that changed is a wrong answer,
    /// not a thin one. Compared first, the change survives with its values hidden.
    public func apply(to comparison: FlowComparison) -> FlowComparison {
        var copy = comparison
        copy.request.url = comparison.request.url.map(redact(urlChange:))
        copy.request.headers = comparison.request.headers.map(redact(headerChange:))
        copy.response.headers = comparison.response.headers.map(redact(headerChange:))
        return copy
    }

    // MARK: - Pieces

    private func redact(headers: [HeaderPair]) -> [HeaderPair] {
        guard !headerNames.isEmpty else { return headers }
        return headers.map { header in
            let secret = headerNames.contains { $0.caseInsensitiveCompare(header.name) == .orderedSame }
            // Keep the header, lose the value — "there was a token here" is
            // information the reader needs.
            return secret ? HeaderPair(name: header.name, value: Self.placeholder) : header
        }
    }

    /// Replace the values of credential-bearing query parameters, leaving the rest of
    /// the URL — path, other parameters, order — exactly as captured. Public for a
    /// render that carries a bare URL rather than a flow (`get_stats`' slowest list).
    public func redacted(url: String) -> String { redact(url: url) }

    private func redact(url: String) -> String {
        guard !queryKeys.isEmpty,
              var components = URLComponents(string: url),
              let items = components.queryItems, !items.isEmpty
        else { return url }

        var touched = false
        components.queryItems = items.map { item in
            guard queryKeys.contains(where: { $0.caseInsensitiveCompare(item.name) == .orderedSame }) else {
                return item
            }
            touched = true
            return URLQueryItem(name: item.name, value: Self.placeholder)
        }
        guard touched else { return url }
        return components.string ?? url
    }

    private func redact(urlChange: FlowComparison.ValueChange<String>) -> FlowComparison.ValueChange<String> {
        var copy = urlChange
        copy.base = urlChange.base.map(redact(url:))
        copy.compared = urlChange.compared.map(redact(url:))
        return copy
    }

    private func redact(headerChange: FlowComparison.HeaderChange) -> FlowComparison.HeaderChange {
        guard headerNames.contains(where: { $0.caseInsensitiveCompare(headerChange.name) == .orderedSame }) else {
            return headerChange
        }
        var copy = headerChange
        copy.base = headerChange.base?.map { _ in Self.placeholder }
        copy.compared = headerChange.compared?.map { _ in Self.placeholder }
        return copy
    }

    private func redact(outcome: FlowOutcome) -> FlowOutcome {
        switch outcome {
        case .pending:
            return .pending
        case let .streaming(response):
            return .streaming(redact(response: response))
        case let .completed(response, at):
            return .completed(redact(response: response), at: at)
        case let .failed(error, at, partial):
            return .failed(error, at: at, partialResponse: partial.map(redact(response:)))
        }
    }

    /// A frame keeps its direction, kind, ordering and timestamp; only the bytes go.
    /// `WebSocketMessage.payload` is non-optional and carries no separate size, so
    /// the marker states the byte count — same principle as a dropped body keeping
    /// `fullBodyBytes`: a reader must be able to tell an emptied frame from an empty
    /// one.
    private func redact(message: WebSocketMessage) -> WebSocketMessage {
        guard !message.payload.isEmpty else { return message }
        var copy = message
        copy.payload = Data("\(Self.placeholder) \(message.payload.count) bytes".utf8)
        return copy
    }

    private func redact(response: CapturedResponse) -> CapturedResponse {
        var copy = response
        copy.headers = redact(headers: response.headers)
        if dropBodies, let body = copy.body {
            copy.fullBodyBytes = copy.fullBodyBytes ?? body.count
            copy.body = nil
        }
        return copy
    }
}
