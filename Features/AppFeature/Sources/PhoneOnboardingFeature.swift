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
        case delegate(Delegate)

        public enum Delegate: Sendable, Equatable {
            /// Bubble the new setting up so the parent persists it and lights the
            /// phone icon accordingly.
            case lanEnabledChanged(Bool)
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
                if enabled {
                    state.isLoading = true
                    return .merge(
                        .send(.delegate(.lanEnabledChanged(true))),
                        .run { send in
                            do { await send(.started(try await proxyClient.startPhoneOnboarding())) }
                            catch { await send(.failed(error.localizedDescription)) }
                        }
                    )
                }
                // Off: drop the material and return the proxy to loopback-only.
                state.info = nil
                state.isLoading = false
                return .merge(
                    .send(.delegate(.lanEnabledChanged(false))),
                    .run { _ in await proxyClient.stopPhoneOnboarding() }
                )

            case let .started(info):
                state.isLoading = false
                state.info = info
                return .none

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
