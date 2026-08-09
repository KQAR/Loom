import Foundation

/// Where a page of flows ended, so the next one can resume from it.
///
/// **Keyset, not an offset**, for two reasons that both bite at 20 000 rows. An
/// `OFFSET` makes SQLite walk and discard every preceding row, so paging deeper costs
/// more each time — and, worse, an offset is a position in a list the capture keeps
/// prepending to: by the time page 3 is asked for, N new flows have arrived and the
/// offset now points somewhere else, so rows are silently skipped or repeated. A key
/// is a value in the ordering, and the ordering doesn't move under it.
///
/// The tiebreak is not decoration: `startedAt` collides routinely — a page load fires
/// a dozen requests inside the same millisecond, and h2 multiplexes more — and two
/// rows sharing the key would make the seek ambiguous, so a page boundary landing
/// between them would drop one or repeat one. Ids are compared by `uuidString`, the
/// same total order the SQLite column has, so the in-memory and on-disk halves of a
/// page agree about what "before" means.
public struct FlowCursor: Equatable, Sendable, Codable {
    public var startedAt: Date
    public var id: UUID

    public init(startedAt: Date, id: UUID) {
        self.startedAt = startedAt
        self.id = id
    }

    public init(_ flow: Flow) {
        self.init(startedAt: flow.startedAt, id: flow.id)
    }

    /// Newest-first ordering: later `startedAt` first, `uuidString` descending as the
    /// tiebreak. One definition, used by the ring scan, the SQL `ORDER BY` and the
    /// merge of the two — three places that must not disagree about row order.
    public static func isOrderedBefore(_ a: Flow, _ b: Flow) -> Bool {
        if a.startedAt != b.startedAt { return a.startedAt > b.startedAt }
        return a.id.uuidString > b.id.uuidString
    }

    /// Whether `flow` falls strictly after this cursor in newest-first order — i.e.
    /// belongs to a later page.
    public func precedes(_ flow: Flow) -> Bool {
        if flow.startedAt != startedAt { return flow.startedAt < startedAt }
        return flow.id.uuidString < id.uuidString
    }
}

/// One page of the capture, newest-first.
///
/// The list surface reads the capture through this instead of holding it: a 20 000-row
/// window costs 20 000 × ~1.3 KB of metadata if every row is resident, and that is the
/// cost this exists to not pay. Bodies are out of line as always — a page is
/// metadata-only, and `flow(id:)` hydrates when a row is opened.
public struct FlowPage: Equatable, Sendable {
    /// Newest-first, at most the requested limit.
    public var flows: [Flow]
    /// Resume point for the next page. Nil means this page reached the end of what is
    /// retained — deliberately distinct from an empty `flows` on a page that merely
    /// found nothing matching before its scan budget ran out.
    public var nextCursor: FlowCursor?
    /// Every flow retained, in memory and on disk, matching the same query. What a row
    /// count is drawn from; nil when the store can't say (no persistence).
    public var totalCount: Int?

    public init(flows: [Flow], nextCursor: FlowCursor? = nil, totalCount: Int? = nil) {
        self.flows = flows
        self.nextCursor = nextCursor
        self.totalCount = totalCount
    }
}
