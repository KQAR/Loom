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
            /// An agent wrote something the human's surfaces hold a copy of. The
            /// parent owns those copies (directly, or through a child), so it is the
            /// one that re-reads them.
            case mirroredStateWriteRecorded
        }
    }

    /// Write tools whose effect already reaches the human through a live stream, so
    /// re-reading on them would be redundant work — flows and breakpoints each have
    /// their own subscription, and `replay_flow` arrives in batches of up to a
    /// hundred.
    ///
    /// **This is an opt-out list, and the direction is the point.** It used to be an
    /// allowlist (`listenerAffectingTools`) naming the two reverse-proxy tools, out
    /// of twenty write tools — so every other agent write (a rule, an SSL-scope
    /// carve-out, a client identity, the capture gate) reached the human only if they
    /// happened to reopen the surface. The status-bar panel re-reads on every open,
    /// which is what hid this; the main window's `.task` fires **once per launch**,
    /// and it is the one that stays open.
    ///
    /// Inverted, the cost of forgetting a new tool is a redundant in-memory read
    /// instead of a surface that quietly disagrees with the engine. Anything added
    /// here needs a live stream to point at.
    static let liveStreamedTools: Set<String> = [
        "replay_flow", "clear_flows", "import_har",   // → flowStream / flowsClearedStream
        "arm_breakpoint", "disarm_breakpoint", "resume", // → pendingBreakpointStream
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
                // What an agent wrote has to show up on the human's surfaces without
                // waiting for one to be reopened — same reason `BreakpointsFeature`
                // re-syncs after every write. The audit stream is already the one
                // signal every write tool passes through, which is why the re-read
                // hangs off it rather than off twenty individual call sites.
                //
                // A failed write changed nothing, so there is nothing to re-read.
                guard entry.succeeded, !Self.liveStreamedTools.contains(entry.tool) else { return .none }
                return .send(.delegate(.mirroredStateWriteRecorded))

            case .clearTapped:
                state.entries.removeAll()
                return .run { _ in await proxyClient.clearAudit() }

            case .delegate:
                return .none
            }
        }
    }
}
