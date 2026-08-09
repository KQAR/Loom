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

    /// A copy whose bodies are dropped **and cannot be got back** — the ring is over
    /// its byte budget and there is no store to hydrate from.
    ///
    /// Distinct from `strippingBodies()` for a reason worth stating: that one is a
    /// *move*, and a slimmed flow is honest as-is, because `FlowStore.hydrated` reads
    /// the bytes back off disk on the next detail/replay/export. This one is a *loss*.
    /// Left as a plain strip, the flow would then say `body == nil`, which does not
    /// mean "the body is elsewhere" — it means "this exchange had no body", and that
    /// is a wrong statement rather than a thin one. The same failure as a diff calling
    /// two capped bodies identical.
    ///
    /// So the wire size is recorded where it already has readers: `fullBodyBytes` on
    /// each side, which makes `isBodyTruncated` true and lights up `captureTruncated`,
    /// `bodyBytesOnWire` and `FlowComparison`'s `.tailNotCaptured` with no new
    /// plumbing. A body that was *already* a capped prefix keeps its original wire
    /// size — the prefix simply becomes empty. `bodiesEvicted` says which of the two
    /// happened, because the reader's next move differs: raise the capture cap, or
    /// turn on persistence.
    func evictingBodies() -> Flow {
        var copy = self
        copy.request = copy.request.discardingBody()
        copy.outcome = outcome.discardingBody()
        copy.bodiesEvicted = true
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

    func discardingBody() -> FlowOutcome {
        switch self {
        case .pending: return .pending
        case let .streaming(response): return .streaming(response.discardingBody())
        case let .completed(response, at): return .completed(response.discardingBody(), at: at)
        case let .failed(error, at, partial): return .failed(error, at: at, partialResponse: partial?.discardingBody())
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

private extension CapturedRequest {
    /// Drop the body, recording what flowed. Keeps an existing `fullBodyBytes` — a
    /// body already capped at capture keeps its true wire size, and its prefix simply
    /// becomes empty.
    func discardingBody() -> CapturedRequest {
        guard let body, !body.isEmpty else { return self }
        var copy = self
        copy.fullBodyBytes = fullBodyBytes ?? body.count
        copy.body = nil
        return copy
    }
}

private extension CapturedResponse {
    func strippingBody() -> CapturedResponse {
        var copy = self
        copy.body = nil
        return copy
    }

    /// See `CapturedRequest.discardingBody()`.
    func discardingBody() -> CapturedResponse {
        guard let body, !body.isEmpty else { return self }
        var copy = self
        copy.fullBodyBytes = fullBodyBytes ?? body.count
        copy.body = nil
        return copy
    }

    func attachingBody(_ body: Data?) -> CapturedResponse {
        var copy = self
        copy.body = body
        return copy
    }
}
