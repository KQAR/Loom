import ComposableArchitecture
import Foundation
import LoomSharedModels
import ProxyClient

/// The breakpoint-supervision surface, split out of `AppFeature` the way
/// `RulesFeature` is. Breakpoints are the one write action where the "AI operates,
/// human supervises" contract genuinely breaks without a view: an armed breakpoint
/// parks a **live client connection** until someone resumes it, so an agent that
/// arms one over MCP and then goes quiet leaves real traffic stalled with nothing
/// in the human's surface showing it — or releasing it.
///
/// The agent still owns *editing* a held exchange (that's `resume` over MCP, with
/// the full `BreakpointEdit`). This surface deliberately offers only the two
/// decisions a supervisor needs: let it through unmodified, or abort it. A
/// half-featured header/body editor here would be a second write path onto the
/// same continuation for no gain.
///
/// State is mirrored from the engine, never owned: a hold can also vanish without
/// anyone deciding anything (the client hangs up, or the watchdog times the hold
/// out), so a resolved hold is not something this reducer can infer from its own
/// writes. Hence the re-sync after every write, plus a slow poll that runs *only*
/// while something is held.
@Reducer
public struct BreakpointsFeature: Sendable {
    @ObservableState
    public struct State: Equatable {
        /// Armed breakpoints, mirrored from the engine (not persisted there — a
        /// hold can't outlive the process, so neither should the arming).
        public var armed: IdentifiedArrayOf<Breakpoint> = []
        /// Exchanges held right now, oldest first. Bounded by physics rather than a
        /// cap: each entry is one parked live connection.
        public var pending: IdentifiedArrayOf<PendingBreakpoint> = []
        /// Transient error from a failed resume/disarm, shown in the panel.
        public var message: String?
        /// Whether the "something is held" poll is running, so repeated holds don't
        /// restart the ticker (which would keep pushing the next tick out).
        var polling = false

        public var heldCount: Int { pending.count }
        /// Anything worth showing in the status-bar panel at all.
        public var isActive: Bool { !pending.isEmpty || !armed.isEmpty }

        public init() {}
    }

    public enum Action: Sendable {
        /// One-shot boot: seed current state, then follow the hold stream.
        case task
        /// Cheap re-sync (panel/window open, after a write, and the held-poll tick).
        case refresh
        case loaded(armed: [Breakpoint], pending: [PendingBreakpoint])
        /// An exchange was just parked (live stream).
        case pendingReceived(PendingBreakpoint)
        /// Let the held exchange continue, unmodified.
        case resumeTapped(PendingBreakpoint.ID)
        /// Kill the held exchange (the client gets a 502).
        case abortTapped(PendingBreakpoint.ID)
        case disarmTapped(Breakpoint.ID)
        case writeFailed(String)
    }

    @Dependency(\.proxyClient) var proxyClient
    @Dependency(\.continuousClock) var clock

    /// How often the UI re-checks held exchanges while at least one is held. Only
    /// covers holds that resolve *without* a decision from us (client hangup, the
    /// engine's watchdog); every deliberate release re-syncs immediately.
    static let heldPollInterval: Duration = .seconds(2)

    private enum CancelID { case holds, poll }

    public init() {}

    public var body: some ReducerOf<Self> {
        Reduce { state, action in
            switch action {
            case .task:
                return .merge(
                    .send(.refresh),
                    .run { send in
                        for await pending in await proxyClient.pendingBreakpointStream() {
                            await send(.pendingReceived(pending))
                        }
                    }
                    .cancellable(id: CancelID.holds, cancelInFlight: true)
                )

            case .refresh:
                return .run { send in
                    await send(.loaded(
                        armed: proxyClient.armedBreakpoints(),
                        pending: proxyClient.pendingBreakpoints()
                    ))
                }

            case let .loaded(armed, pending):
                state.armed = IdentifiedArray(uniqueElements: armed)
                state.pending = IdentifiedArray(uniqueElements: pending)
                return Self.syncPolling(&state, clock: clock)

            case let .pendingReceived(pending):
                // The stream can beat the seed read, so this is an upsert, not an
                // append — a hold must never appear twice in the human's list.
                state.pending[id: pending.id] = pending
                return Self.syncPolling(&state, clock: clock)

            case let .resumeTapped(id):
                return resolve(&state, id: id, abort: false)

            case let .abortTapped(id):
                return resolve(&state, id: id, abort: true)

            case let .disarmTapped(id):
                state.message = nil
                state.armed.remove(id: id) // optimistic; re-synced below
                return .run { send in
                    do { try await proxyClient.disarmBreakpoint(id) }
                    catch { await send(.writeFailed("Couldn’t disarm: \(error.localizedDescription)")) }
                    await send(.refresh)
                }

            case let .writeFailed(message):
                state.message = message
                return .none
            }
        }
    }

    /// Release a held exchange, optimistically dropping it from the list. The
    /// re-sync afterwards is what keeps the list honest if the engine disagreed
    /// (the hold had already resolved, so `resume` throws).
    private func resolve(_ state: inout State, id: PendingBreakpoint.ID, abort: Bool) -> Effect<Action> {
        state.message = nil
        state.pending.remove(id: id)
        let verb = abort ? "abort" : "resume"
        return .merge(
            Self.syncPolling(&state, clock: clock),
            .run { send in
                do { try await proxyClient.resumeBreakpoint(id, abort, .none) }
                catch { await send(.writeFailed("Couldn’t \(verb) the held exchange: \(error.localizedDescription)")) }
                await send(.refresh)
            }
        )
    }

    /// Start the held-poll when the first hold appears, stop it when the last one
    /// goes. A ticker that ran unconditionally would wake the reducer forever for
    /// the overwhelmingly common case of nothing being held.
    private static func syncPolling(_ state: inout State, clock: any Clock<Duration>) -> Effect<Action> {
        let shouldPoll = !state.pending.isEmpty
        guard shouldPoll != state.polling else { return .none }
        state.polling = shouldPoll
        guard shouldPoll else { return .cancel(id: CancelID.poll) }
        return .run { send in
            while !Task.isCancelled {
                try? await clock.sleep(for: heldPollInterval)
                await send(.refresh)
            }
        }
        .cancellable(id: CancelID.poll, cancelInFlight: true)
    }
}
