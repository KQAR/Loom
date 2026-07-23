import ComposableArchitecture
import Foundation
import SharedModels

/// Drives the phone-onboarding popover: on present it asks the engine to make the
/// proxy LAN-reachable and publish the QR + download server; the parent stops
/// onboarding when the popover is dismissed. Embedded via `@Presents`.
@Reducer
public struct PhoneOnboardingFeature: Sendable {
    @ObservableState
    public struct State: Equatable {
        public var info: PhoneOnboardingInfo?
        public var isLoading = false
        public var errorMessage: String?
        public init() {}
    }

    public enum Action: Sendable {
        /// Popover appeared — start onboarding once.
        case task
        case started(PhoneOnboardingInfo)
        case failed(String)
    }

    @Dependency(\.proxyClient) var proxyClient

    public init() {}

    public var body: some ReducerOf<Self> {
        Reduce { state, action in
            switch action {
            case .task:
                // Guard so a re-render can't restart onboarding mid-flight.
                guard state.info == nil, !state.isLoading else { return .none }
                state.isLoading = true
                state.errorMessage = nil
                return .run { send in
                    do {
                        let info = try await proxyClient.startPhoneOnboarding()
                        await send(.started(info))
                    } catch {
                        await send(.failed(error.localizedDescription))
                    }
                }

            case let .started(info):
                state.isLoading = false
                state.info = info
                return .none

            case let .failed(message):
                state.isLoading = false
                state.errorMessage = message
                return .none
            }
        }
    }
}
