import ComposableArchitecture
import Foundation
import LoomSharedModels
import ProxyClient

/// The console's Reverse Proxies section, split out of `AppFeature`.
///
/// The endpoints themselves are **projected, not owned** — they live in
/// `status.reverseProxies`, the one mirror, re-read after every write, because the
/// bound port is only knowable after the create and an agent is the other writer.
/// Copying them into this feature's state would be the second list the card's own
/// doc comment argues against. Same shape as `SetupFeature`'s `port`/`proxyRunning`:
/// the parent fills them in on read from the single source of truth, so there is
/// nothing to keep in sync.
///
/// What this feature owns is only the section's own state: whether it is open, and
/// the outcome of the human's last create/delete. Both writes ask the parent to
/// re-read the status afterwards (`delegate`), because a create binds a port and a
/// delete closes one — the list is only as fresh as its last load.
@Reducer
public struct ReverseProxyFeature: Sendable {
    @ObservableState
    public struct State: Equatable {
        /// Filled in by the parent on read from `status.reverseProxies`. Never
        /// assigned by this reducer — see the type's doc comment.
        public var endpoints: [ReverseProxyStatus] = []
        /// Collapsed by default, like Client Certificates: a dev server is pointed at
        /// an endpoint once and then the endpoint just sits there.
        public var isExpanded = false
        /// A create or delete is in flight (a create binds a port, so it can fail).
        public var isBusy = false
        /// Why the last create/delete failed, verbatim from the engine. Nil on
        /// success: the new (or now-absent) endpoint in the list is the confirmation.
        public var message: String?

        public init() {}
    }

    public enum Action: Sendable {
        case expandTapped
        case addTapped(upstream: String, port: Int, label: String?, keepHostHeader: Bool)
        case deleteTapped(id: UUID)
        case finished(message: String?)
        case delegate(Delegate)

        @CasePathable
        public enum Delegate: Sendable, Equatable {
            /// The set of listening ports may have changed — the parent owns `status`
            /// and is the one that re-reads it.
            case needsStatusRefresh
        }
    }

    @Dependency(\.proxyClient) var proxyClient

    public init() {}

    public var body: some ReducerOf<Self> {
        Reduce { state, action in
            switch action {
            case .expandTapped:
                state.isExpanded.toggle()
                // Opening is also a re-read, same as the client-certificate section:
                // an agent can have created or removed an endpoint since the last
                // status refresh.
                guard state.isExpanded else { return .none }
                return .send(.delegate(.needsStatusRefresh))

            case let .addTapped(upstream, port, label, keepHostHeader):
                state.isBusy = true
                state.message = nil
                return .run { send in
                    do {
                        _ = try await proxyClient.createReverseProxy(ReverseProxyEndpoint(
                            requestedPort: port, upstream: upstream,
                            label: label, keepHostHeader: keepHostHeader
                        ))
                        // The create binds before it persists, so a success means the
                        // port is listening — re-read to pick up the *bound* port,
                        // which is the number the human points their client at (and is
                        // not the requested one when 0 asked the OS to choose).
                        await send(.delegate(.needsStatusRefresh))
                        await send(.finished(message: nil))
                    } catch {
                        // The engine validates the upstream and the bind on the way in,
                        // so its message already names what the human can fix (no
                        // scheme, port in use). Relay it verbatim.
                        let message = (error as? ProxyControlError)?.message ?? error.localizedDescription
                        await send(.finished(message: message))
                    }
                }

            case let .deleteTapped(id):
                state.isBusy = true
                state.message = nil
                return .run { send in
                    do {
                        try await proxyClient.deleteReverseProxy(id)
                        await send(.delegate(.needsStatusRefresh))
                        await send(.finished(message: nil))
                    } catch {
                        let message = (error as? ProxyControlError)?.message ?? error.localizedDescription
                        await send(.finished(message: message))
                    }
                }

            case let .finished(message):
                state.isBusy = false
                state.message = message
                return .none

            case .delegate:
                return .none
            }
        }
    }
}
