import ComposableArchitecture
import Foundation
import LoomSharedModels

/// Drives the phone-onboarding popover: shows the QR + proxy address and hosts
/// the LAN-device-connection switch. LAN reachability is a persistent app-level
/// setting (owned by the parent, default on) — this feature reflects and toggles
/// it; presenting/dismissing the popover no longer starts or stops it. Embedded
/// via `@Presents`; the parent is told about switch changes through `.delegate`.
@Reducer
public struct PhoneOnboardingFeature: Sendable {
    @ObservableState
    public struct State: Equatable {
        /// Seeded from the parent's persisted setting when the popover opens.
        public var lanEnabled: Bool
        public var info: PhoneOnboardingInfo?
        public var isLoading = false
        public var errorMessage: String?
        public init(lanEnabled: Bool, info: PhoneOnboardingInfo? = nil) {
            self.lanEnabled = lanEnabled
            self.info = info
        }
    }

    public enum Action: Sendable {
        /// Popover appeared — fetch the QR/address material if LAN is on.
        case task
        /// The top-right switch flipped: run or stop LAN device connection.
        case setLANEnabled(Bool)
        case started(PhoneOnboardingInfo)
        case failed(String)
        /// The listener came back to loopback and the material is gone.
        case lanStopped
        /// The engine refused the move. `revertTo` is what is *actually* true now,
        /// which is the value the switch has to return to.
        case lanChangeFailed(String, revertTo: Bool)
        case delegate(Delegate)

        public enum Delegate: Sendable, Equatable {
            /// Bubble the new setting up so the parent persists it and lights the
            /// phone icon accordingly.
            case lanEnabledChanged(Bool)
            /// Material was published for this LAN address. The parent tracks it so
            /// it can tell when the machine's address has moved out from under an
            /// already-published QR — which it can only do if it knows what the QR
            /// was published *for*, and this popover is gone the moment it closes.
            case published(PhoneOnboardingInfo)
        }
    }

    @Dependency(\.proxyClient) var proxyClient

    public init() {}

    public var body: some ReducerOf<Self> {
        Reduce { state, action in
            switch action {
            case .task:
                // LAN is already running (started at boot); `startPhoneOnboarding`
                // is idempotent and republishes, so this just fetches the material.
                guard state.lanEnabled, state.info == nil, !state.isLoading else { return .none }
                state.isLoading = true
                state.errorMessage = nil
                return .run { send in
                    do { await send(.started(try await proxyClient.startPhoneOnboarding())) }
                    catch { await send(.failed(error.localizedDescription)) }
                }

            case let .setLANEnabled(enabled):
                state.lanEnabled = enabled
                state.errorMessage = nil
                // The switch moves *the listener*, and a listener move can be refused
                // — the port Loom needs on the other interface may be held by
                // something else. Both directions are therefore optimistic-then-
                // reverted rather than fire-and-forget: the engine is asked, and if it
                // says no the switch goes back to what is actually true. Leaving it
                // where the finger put it is a promise about who can reach this
                // machine, quietly not kept.
                if enabled {
                    state.isLoading = true
                    return .merge(
                        .send(.delegate(.lanEnabledChanged(true))),
                        .run { send in
                            do { await send(.started(try await proxyClient.startPhoneOnboarding())) }
                            catch {
                                await send(.lanChangeFailed(error.localizedDescription, revertTo: false))
                            }
                        }
                    )
                }
                // Off: return the proxy to loopback-only, then drop the material.
                state.isLoading = true
                return .merge(
                    .send(.delegate(.lanEnabledChanged(false))),
                    .run { send in
                        do {
                            try await proxyClient.stopPhoneOnboarding()
                            await send(.lanStopped)
                        } catch {
                            await send(.lanChangeFailed(error.localizedDescription, revertTo: true))
                        }
                    }
                )

            case .lanStopped:
                state.isLoading = false
                state.info = nil
                return .none

            case let .lanChangeFailed(message, revertTo):
                state.isLoading = false
                state.errorMessage = message
                state.lanEnabled = revertTo
                // The parent persisted the optimistic value and re-read `listenHost`
                // off the back of it, so the correction has to travel the same way —
                // otherwise the console's phone glyph keeps the answer the engine
                // refused.
                return .send(.delegate(.lanEnabledChanged(revertTo)))

            case let .started(info):
                state.isLoading = false
                state.info = info
                return .send(.delegate(.published(info)))

            case let .failed(message):
                state.isLoading = false
                state.errorMessage = message
                return .none

            case .delegate:
                return .none
            }
        }
    }
}
