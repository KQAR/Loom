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
    /// Drop request and response bodies entirely (their sizes are kept). The blunt
    /// instrument for "I can't audit every payload, so send none of them".
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
        return copy
    }

    public func apply(to flows: [Flow]) -> [Flow] {
        flows.map(apply(to:))
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
    /// the URL — path, other parameters, order — exactly as captured.
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
