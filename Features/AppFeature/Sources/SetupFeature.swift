import ComposableArchitecture
import Foundation
import PrivilegedHelperClient
import ProxyClient
import LoomSharedModels

/// The "make Loom capture" setup surface, split out of `AppFeature`: the system
/// proxy toggle, HTTPS-interception (SSL) toggle, and the root-CA trust card.
/// These are the M2 controls the human drives from the panel; the agent narrows
/// SSL scope over MCP. Embedded via `Scope`.
///
/// System-proxy actions need the proxy's port + running state, which the parent
/// owns (`status`); the parent mirrors them into `port`/`proxyRunning` here (the
/// standard "child needs a slice of parent state" pattern) so this feature stays
/// self-contained and testable.
@Reducer
public struct SetupFeature: Sendable {
    @ObservableState
    public struct State: Equatable {
        // Mirrored from the parent's ProxyStatus.
        public var port = 9090
        public var proxyRunning = false

        public var isSystemProxy = false          // M2: routed via networksetup
        public var systemProxyBusy = false        // change in flight
        public var systemProxyMessage: String?    // transient feedback under the row
        /// Where traffic actually goes, followed live. Kept alongside
        /// `isSystemProxy` rather than replacing it because the toggle sets that one
        /// optimistically before the system has been asked; this one is only ever
        /// what macOS reported.
        public var systemProxyRouting = SystemProxyRouting.off

        public var sslEnabled = false             // M2: HTTPS interception (SSL parsing)
        public var sslScope = SSLScope.disabled   // interception scope (include/exclude globs)
        public var certificateStatus = CertificateStatus.notGenerated
        public var certBusy = false               // a trust action is running
        public var certActionMessage: String?     // transient feedback under the cert card

        /// Mutual-TLS identities Loom presents when an origin demands one, secrets
        /// stripped. Mirrored here rather than read on demand because the human's
        /// half of the contract is *seeing* what an agent installed — an identity
        /// that only exists in the engine is an invisible write.
        public var clientCertificates: [ClientCertificateSummary] = []
        public var clientCertBusy = false
        public var clientCertMessage: String?
        /// Whether the panel's client-certificate section is expanded. Collapsed by
        /// default: this is the lowest-frequency configuration Loom has, so it earns
        /// a row, not permanent space.
        public var clientCertsExpanded = false

        /// Identities that can't do their job — expired, or a bundle that no longer
        /// reads. Both fail a handshake exactly like having no identity at all, which
        /// is why the row surfaces a count instead of waiting to be opened.
        public var brokenClientCertificates: [ClientCertificateSummary] {
            clientCertificates.filter { $0.isExpired() || $0.problem != nil }
        }

        public init() {}
    }

    public enum Action: Sendable {
        /// Long-running subscription: follow the system proxy for as long as the app
        /// lives. Started by the parent, next to the other `.task` subscriptions.
        case task
        /// Cheap re-sync of all setup state when a window/panel appears.
        case refresh
        case toggleSystemProxyTapped
        case systemProxyResult(enabling: Bool, ok: Bool, message: String?)
        case systemProxyStateLoaded(Bool)
        /// macOS reported new proxy settings — either someone else changed them, or
        /// our own write landed.
        case systemProxySnapshotChanged(SystemProxySnapshot)
        case toggleSSLTapped
        case certificateStatusLoaded(CertificateStatus)
        case sslScopeLoaded(SSLScope)
        case exportCATapped
        case caExported(URL?)
        case installAndTrustCATapped
        case recheckCertTapped
        case certActionStarted(String)
        case certActionFinished(message: String?)

        // MARK: Mutual TLS
        case clientCertsExpandTapped
        case clientCertificatesLoaded([ClientCertificateSummary])
        /// The human picked a `.p12` and filled in the form. The file is read in the
        /// effect, not the view: a view that loads key material would put it on the
        /// main thread and into a `@State` that outlives the sheet.
        case addClientCertificate(url: URL, hostPattern: String, passphrase: String, label: String)
        case deleteClientCertificateTapped(id: UUID)
        case clientCertFinished(message: String?)
    }

    @Dependency(\.proxyClient) var proxyClient
    @Dependency(\.privilegedHelperClient) var privilegedHelperClient

    public init() {}

    public var body: some ReducerOf<Self> {
        Reduce { state, action in
            switch action {
            case .task:
                return .run { send in
                    for await snapshot in privilegedHelperClient.systemProxySnapshots() {
                        await send(.systemProxySnapshotChanged(snapshot))
                    }
                }

            case .refresh:
                let port = state.port
                return .run { send in
                    await send(.systemProxySnapshotChanged(privilegedHelperClient.systemProxySnapshot()))
                    await send(.certificateStatusLoaded(proxyClient.certificateStatus()))
                    await send(.sslScopeLoaded(proxyClient.sslScope()))
                    // Re-read on every appearance, because the other writer is an
                    // agent: an identity can appear without the human doing anything.
                    await send(.clientCertificatesLoaded(proxyClient.clientCertificates()))
                }

            // MARK: System proxy

            case let .systemProxyStateLoaded(active):
                state.isSystemProxy = active
                return .none

            case let .systemProxySnapshotChanged(snapshot):
                // Ignore while our own change is in flight. The enable script writes
                // each network service in turn, so mid-apply snapshots are genuinely
                // half-applied; letting them through would flicker the switch and
                // fight the optimistic value. `.systemProxyResult` re-reads once the
                // write has settled.
                guard !state.systemProxyBusy else { return .none }
                // Classified here, not in the effect: the port can change under us
                // (phone onboarding rebinds the proxy), so the comparison has to use
                // the port as of delivery rather than as of subscription.
                let routing = snapshot.routing(loomPort: state.port)
                state.systemProxyRouting = routing
                state.isSystemProxy = routing == .loom
                return .none

            case .toggleSystemProxyTapped:
                guard state.proxyRunning || !state.isSystemProxy else {
                    state.systemProxyMessage = "Start the proxy first."
                    return .none
                }
                let enabling = !state.isSystemProxy
                state.isSystemProxy = enabling // optimistic; reverted if it fails
                state.systemProxyBusy = true
                state.systemProxyMessage = enabling ? "Setting system proxy…" : "Removing system proxy…"
                let port = state.port
                // No privileged helper needed: applied via networksetup under one
                // admin prompt (see PrivilegedHelperClient.setSystemProxy).
                return .run { send in
                    let outcome = await privilegedHelperClient.setSystemProxy(enabling, port)
                    await send(.systemProxyResult(enabling: enabling, ok: outcome.ok, message: outcome.message))
                }

            case let .systemProxyResult(enabling, ok, message):
                state.systemProxyBusy = false
                // Settle on what the system actually says now: snapshots are ignored
                // while busy, so nothing has been believed since the toggle, and a
                // write that half-landed must not leave the row asserting the
                // optimistic value.
                let settle = Effect<Action>.run { send in
                    await send(.systemProxySnapshotChanged(privilegedHelperClient.systemProxySnapshot()))
                }
                if ok {
                    // No standing claim is stored here. The "QUIC is blocked" note is a
                    // fact about the *current* routing, not feedback about this action,
                    // so the panel derives it from `systemProxyRouting`. Storing it as
                    // text is what let it outlive the state it described: another proxy
                    // app would take the setting, the row would correctly read "in use
                    // by 127.0.0.1:8888", and the note underneath would still be
                    // claiming Loom had it and would restore it on quit.
                    state.systemProxyMessage = nil
                } else {
                    state.isSystemProxy = !enabling // revert the optimistic toggle
                    state.systemProxyMessage = message ?? "System proxy change failed."
                }
                return settle

            // MARK: SSL interception

            case .toggleSSLTapped:
                let enabling = !state.sslEnabled
                state.sslEnabled = enabling
                var next = state.sslScope
                next.enabled = enabling
                // First time on with no scope: default to intercept-all; the human
                // or agent narrows it.
                if enabling, next.include.isEmpty { next.include = ["*"] }
                state.sslScope = next
                let scope = next
                return .run { send in
                    await proxyClient.setSSLScope(scope)
                    await send(.certificateStatusLoaded(proxyClient.certificateStatus()))
                }

            case let .certificateStatusLoaded(status):
                state.certificateStatus = status
                return .none

            case let .sslScopeLoaded(scope):
                state.sslScope = scope
                state.sslEnabled = scope.enabled
                return .none

            // MARK: Root-CA trust

            case .exportCATapped:
                return .run { send in
                    let url = try? await proxyClient.exportCACertificate()
                    await send(.caExported(url))
                }

            case let .caExported(url):
                if let url {
                    state.certificateStatus.exportedPEMPath = url.path
                    RevealInFinder.reveal(path: url.path)
                }
                return .none

            case .installAndTrustCATapped:
                // In-app trust for the current user: add the CA to the login keychain
                // and set user-domain trust. No privileged helper or Developer ID
                // needed — macOS prompts once for the login password.
                return .run { send in
                    await send(.certActionStarted("Requesting trust — enter your login password…"))
                    let result = await proxyClient.trustCertificate()
                    await send(.certificateStatusLoaded(proxyClient.certificateStatus()))
                    await send(.certActionFinished(
                        message: result.ok ? "Trusted. HTTPS interception is ready." : (result.message ?? "Trust was not granted.")
                    ))
                }

            case .recheckCertTapped:
                return .run { send in
                    await send(.certActionStarted("Re-checking trust…"))
                    await send(.certificateStatusLoaded(proxyClient.certificateStatus()))
                    await send(.certActionFinished(message: nil))
                }

            case let .certActionStarted(message):
                state.certBusy = true
                state.certActionMessage = message
                return .none

            case let .certActionFinished(message):
                state.certBusy = false
                state.certActionMessage = message
                return .none

            // MARK: Mutual TLS (client certificates)

            case .clientCertsExpandTapped:
                state.clientCertsExpanded.toggle()
                // Opening is also a re-read: the list is only as fresh as its last
                // load, and the agent can have written since.
                guard state.clientCertsExpanded else { return .none }
                return .run { send in
                    await send(.clientCertificatesLoaded(proxyClient.clientCertificates()))
                }

            case let .clientCertificatesLoaded(summaries):
                state.clientCertificates = summaries
                return .none

            case let .addClientCertificate(url, hostPattern, passphrase, label):
                state.clientCertBusy = true
                state.clientCertMessage = nil
                return .run { send in
                    do {
                        let bundle = try Data(contentsOf: url)
                        try await proxyClient.setClientCertificate(ClientCertificate(
                            hostPattern: hostPattern, pkcs12: bundle,
                            passphrase: passphrase, label: label
                        ))
                        await send(.clientCertificatesLoaded(proxyClient.clientCertificates()))
                        await send(.clientCertFinished(message: nil))
                    } catch {
                        // The engine validates the bundle on the way in, so the message
                        // it throws already names what the operator can fix (wrong
                        // passphrase / not a .p12). Relay it verbatim.
                        let message = (error as? ProxyControlError)?.message ?? error.localizedDescription
                        await send(.clientCertFinished(message: message))
                    }
                }

            case let .deleteClientCertificateTapped(id):
                state.clientCertBusy = true
                state.clientCertMessage = nil
                return .run { send in
                    do {
                        try await proxyClient.deleteClientCertificate(id)
                        await send(.clientCertificatesLoaded(proxyClient.clientCertificates()))
                        await send(.clientCertFinished(message: nil))
                    } catch {
                        let message = (error as? ProxyControlError)?.message ?? error.localizedDescription
                        await send(.clientCertFinished(message: message))
                    }
                }

            case let .clientCertFinished(message):
                state.clientCertBusy = false
                state.clientCertMessage = message
                return .none
            }
        }
    }
}
