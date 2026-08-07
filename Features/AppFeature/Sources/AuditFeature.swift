import ComposableArchitecture
import Foundation
import LoomSharedModels
import ProxyClient

/// The write-action audit trail, split out of `AppFeature` the way `RulesFeature`
/// and `BreakpointsFeature` are.
///
/// It has no business being in the parent: nothing here touches captured traffic,
/// the proxy's lifecycle or the selection — it is a log with a cap and a Clear
/// button. What kept it there was one coupling, and it is real: two write tools
/// (`create_reverse_proxy` / `delete_reverse_proxy`) change which ports Loom is
/// listening on, so the header's address block has to be re-read when one is
/// recorded. That is now a `delegate` action rather than a reach into the
/// parent's state — the child says what happened, the parent decides what that
/// means for the surface it owns.
@Reducer
public struct AuditFeature: Sendable {
    @ObservableState
    public struct State: Equatable {
        /// Stored oldest-first (newest appended at the end) — the panel shows a
        /// chronological log with the newest at the bottom, like the flow list.
        /// Bounded like that list, so a long session can't grow it unbounded; the
        /// durable store keeps more, surfaced via the `get_audit_log` MCP tool.
        public var entries: IdentifiedArrayOf<AuditEntry> = []
        /// Most entries the window keeps in memory this session.
        public static let displayCap = 500

        public init() {}
    }

    public enum Action: Sendable {
        /// One-shot boot: seed history, then follow the live trail.
        case task
        case entryReceived(AuditEntry)
        case clearTapped
        case delegate(Delegate)

        @CasePathable
        public enum Delegate: Sendable, Equatable {
            /// A write tool that changes which ports Loom is listening on was
            /// recorded. The parent owns `status`, so it is the one that re-reads it.
            case listenerAffectingWriteRecorded
        }
    }

    /// Write tools that change which ports Loom is listening on. A `Set` rather than
    /// a prefix match: "any tool starting with create_" would silently start
    /// refreshing on unrelated writes as tools are added.
    static let listenerAffectingTools: Set<String> = [
        "create_reverse_proxy", "delete_reverse_proxy",
    ]

    @Dependency(\.proxyClient) var proxyClient

    private enum CancelID { case subscription }

    public init() {}

    public var body: some ReducerOf<Self> {
        Reduce { state, action in
            switch action {
            case .task:
                // Seed history, then follow live. One effect: the seed must land
                // before the stream's first entry or a resubscribe could interleave
                // an old entry after a new one.
                return .run { send in
                    for entry in await proxyClient.recentAuditEntries(State.displayCap).reversed() {
                        await send(.entryReceived(entry))
                    }
                    for await entry in await proxyClient.auditStream() {
                        await send(.entryReceived(entry))
                    }
                }
                .cancellable(id: CancelID.subscription, cancelInFlight: true)

            case let .entryReceived(entry):
                // Dedup by id (a re-seed after a resubscribe could repeat), then bound
                // to the display cap by dropping the oldest.
                if let existing = state.entries.index(id: entry.id) {
                    state.entries[existing] = entry
                } else {
                    state.entries.append(entry)
                    if state.entries.count > State.displayCap {
                        state.entries.removeFirst(state.entries.count - State.displayCap)
                    }
                }
                // An agent opening or closing a listening port has to show up in the
                // header without waiting for the panel to be reopened — same reason
                // `BreakpointsFeature` re-syncs after every write. The audit stream is
                // already the one signal every write tool passes through.
                guard Self.listenerAffectingTools.contains(entry.tool) else { return .none }
                return .send(.delegate(.listenerAffectingWriteRecorded))

            case .clearTapped:
                state.entries.removeAll()
                return .run { _ in await proxyClient.clearAudit() }

            case .delegate:
                return .none
            }
        }
    }
}
