import Foundation
import SharedModels

/// Body separation for storage (Layer 1 of large-body governance): request and
/// response bodies are the heavy part of a `Flow`. Persistence stores them in
/// their own BLOB columns and keeps the JSON metadata body-free, so list/boot
/// reads decode cheaply. These helpers strip bodies before encoding and re-attach
/// them on demand — the `Flow` model shape is unchanged, so every reader that
/// reads `.body` off a hydrated flow keeps working.
extension Flow {
    /// A copy with both bodies removed — the shape stored as the JSON metadata
    /// blob and held in the in-memory ring once slimmed.
    func strippingBodies() -> Flow {
        var copy = self
        copy.request.body = nil
        copy.outcome = outcome.strippingBody()
        return copy
    }

    /// A copy with bodies re-attached from separate storage. Nil arguments leave
    /// that side empty (the flow genuinely had no body).
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
