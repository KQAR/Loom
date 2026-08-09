import Foundation

/// The result of a filtered flow read, plus what that result is worth.
///
/// ## Why the second half exists
///
/// A search that came back empty used to say only `[]`, and `[]` had two meanings that
/// could not be told apart: *this traffic was not captured*, and *this traffic is
/// outside what was searched*. The second was the common one — the scan covered the
/// in-memory ring (2000 flows) while the store kept 20 000 — and it sent the reader to
/// debug a client that had worked fine. It is the same shape as an unread `CONNECT`
/// recording no flow at all, which `TunneledHostLog` exists to make visible.
///
/// The scan now reads through to history, so the honest answer is usually "everything
/// retained was searched". This type carries the cases where it isn't:
///
/// - `budgetExhausted` — the history walk stopped at its row budget with the result
///   still short of `limit`. The answer is a *partial* one and must not be reported as
///   exhaustive.
/// - `storedFlowCount` — how many exchanges are retained at all, which is the only
///   honest thing that can be said about traffic older than the store's row cap: it is
///   gone, and no search will find it.
public struct FlowSearchResult: Equatable, Sendable {
    public var flows: [Flow]
    /// The history scan stopped early. `flows` is a partial answer.
    public var budgetExhausted: Bool
    /// Rows the durable store holds, when there is one. Nil means nothing is
    /// persisted (an embedder that owns its storage, or a test seam) — deliberately
    /// distinct from `0`, which means a store exists and is empty.
    public var storedFlowCount: Int?

    public init(flows: [Flow], budgetExhausted: Bool = false, storedFlowCount: Int? = nil) {
        self.flows = flows
        self.budgetExhausted = budgetExhausted
        self.storedFlowCount = storedFlowCount
    }
}
