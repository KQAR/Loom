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
        /// The listener reached the LAN *and* the material was published — the switch's
        /// own success, as opposed to `started`, which is the popover merely fetching
        /// material for a LAN that was already up.
        case lanStarted(PhoneOnboardingInfo)
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
                // The switch's own state moves now — a control that doesn't follow the
                // finger reads as broken — but **the delegate does not**.
                //
                // The delegate is what makes the parent persist the choice and re-read
                // `listenHost`, and this switch *moves the listener*: sending it here
                // put that read in a race with the rebind it was reading the result
                // of. It lost, every time — `status()` answered while the engine was
                // still on the old interface, nothing read it again, and the toolbar
                // went on naming `0.0.0.0` after LAN was switched off, until the next
                // relaunch. Sent from the engine's own answer below instead, so "the
                // parent believes LAN moved" and "it moved" are the same moment.
                //
                // A move can also be refused (the port Loom needs on the other
                // interface may be held by something else), which is the second reason
                // the same ordering is right: a refusal now needs no correction to
                // travel, because nothing was announced.
                state.lanEnabled = enabled
                state.errorMessage = nil
                state.isLoading = true
                if enabled {
                    return .run { send in
                        do { await send(.lanStarted(try await proxyClient.startPhoneOnboarding())) }
                        catch {
                            await send(.lanChangeFailed(error.localizedDescription, revertTo: false))
                        }
                    }
                }
                // Off: return the proxy to loopback-only, then drop the material.
                return .run { send in
                    do {
                        try await proxyClient.stopPhoneOnboarding()
                        await send(.lanStopped)
                    } catch {
                        await send(.lanChangeFailed(error.localizedDescription, revertTo: true))
                    }
                }

            case let .lanStarted(info):
                state.isLoading = false
                state.info = info
                // Both, and only now: the listener is on `0.0.0.0` and the material
                // describes it.
                return .merge(
                    .send(.delegate(.lanEnabledChanged(true))),
                    .send(.delegate(.published(info)))
                )

            case .lanStopped:
                state.isLoading = false
                state.info = nil
                return .send(.delegate(.lanEnabledChanged(false)))

            case let .lanChangeFailed(message, revertTo):
                state.isLoading = false
                state.errorMessage = message
                state.lanEnabled = revertTo
                // No delegate: nothing was announced, so there is nothing to correct.
                // The parent's `lanEnabled` and the persisted choice both still hold
                // the value the engine kept.
                return .none

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
