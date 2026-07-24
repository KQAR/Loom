import Foundation

/// Body separation for large-body governance. Request and response bodies are
/// the heavy part of a `Flow`; the storage layer keeps them in dedicated columns
/// (not the JSON blob), the engine ring drops them once over a byte budget, and
/// the UI holds metadata-only flows and hydrates a body on demand. These helpers
/// strip bodies before storing and re-attach them when a full payload is needed.
/// The `Flow` model shape is unchanged, so every reader of `.body` on a hydrated
/// flow keeps working.
public extension Flow {
    /// A copy with both bodies removed — the shape stored as JSON metadata, held
    /// in the in-memory ring once slimmed, and kept in the UI's flow list.
    func strippingBodies() -> Flow {
        var copy = self
        copy.request.body = nil
        copy.outcome = outcome.strippingBody()
        return copy
    }

    /// A copy with bodies re-attached from separate storage. A nil argument leaves
    /// that side empty (the flow genuinely had no body there).
    func attachingBodies(request requestBody: Data?, response responseBody: Data?) -> Flow {
        var copy = self
        copy.request.body = requestBody
        copy.outcome = outcome.attachingBody(responseBody)
        return copy
    }
}

private extension FlowOutcome {
    func strippingBody() -> FlowOutcome {
        switch self {
        case .pending: return .pending
        case let .streaming(response): return .streaming(response.strippingBody())
        case let .completed(response, at): return .completed(response.strippingBody(), at: at)
        case let .failed(error, at, partial): return .failed(error, at: at, partialResponse: partial?.strippingBody())
        }
    }

    /// Re-attach a response body into whichever case carries a response.
    func attachingBody(_ body: Data?) -> FlowOutcome {
        switch self {
        case .pending: return .pending
        case let .streaming(response): return .streaming(response.attachingBody(body))
        case let .completed(response, at): return .completed(response.attachingBody(body), at: at)
        case let .failed(error, at, partial): return .failed(error, at: at, partialResponse: partial?.attachingBody(body))
        }
    }
}

private extension CapturedResponse {
    func strippingBody() -> CapturedResponse {
        var copy = self
        copy.body = nil
        return copy
    }

    func attachingBody(_ body: Data?) -> CapturedResponse {
        var copy = self
        copy.body = body
        return copy
    }
}
