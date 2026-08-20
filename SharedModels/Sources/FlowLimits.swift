/// How many flows each layer keeps, in one place.
///
/// These three numbers are related — a flow is upserted into the ring, persisted to
/// the store, and projected into the main window's list — and every time one of them
/// moved, a copy of it somewhere else did not. The ring's 2 000 was written as a
/// default argument in three initialisers; the window's cap moved from 2 000 to 20 000
/// and left half a dozen doc comments claiming "the newest 2000" about a list holding
/// ten times that. A number that appears in more than one place is a number that will
/// be adjusted in fewer places than it appears.
///
/// So: change the value here, not at a call site, and never re-type one of these
/// literals. The invariant between them is pinned by `FlowLimitsTests`.
public enum FlowLimits {
    /// The engine's in-memory ring (`FlowStore`). Small on purpose: it is what every
    /// capture write queues behind, and what a read scans before falling through to
    /// the store.
    public static let memoryRing = 2_000

    /// Rows kept in `flows.sqlite`. Fifty times the ring — this is what "retained"
    /// means to a search, and what `get_stats.flowsRetained` counts. It rises with
    /// `windowRows` and never below it (`isOrdered`), so the disk cost is the one that
    /// pays for a bigger list: measured at ~33 KB of file per flow with 32 KB bodies,
    /// the plateau is ~3.2 GB at this cap against 659 MB at the old 20 000.
    public static let persistedRows = 99_999

    /// Rows the main window's list holds. Sits at the store's cap rather than the
    /// ring's: history is read up into the window after launch, and a window smaller
    /// than the store is a table that disagrees with its own search results. Five
    /// digits is also the `#` column's width (`DESIGN.md`), which is why the cap stops
    /// one short of 100 000 rather than at a round number.
    public static let windowRows = 99_999

    /// `memoryRing ≤ windowRows ≤ persistedRows`.
    ///
    /// Stated as a property rather than left implicit because each inequality has a
    /// failure the other numbers cannot show: a ring larger than the window would put
    /// flows in memory the table refuses to draw, and a window larger than the store
    /// would keep rows on screen that no read can ever resolve again — an id that
    /// renders and cannot be opened.
    public static var isOrdered: Bool {
        memoryRing <= windowRows && windowRows <= persistedRows
    }
}
