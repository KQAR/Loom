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

        /// The privileged helper, which is what makes the system-proxy toggle
        /// password-free. Mirrored rather than read on demand because the human can
        /// revoke it in System Settings without Loom being told — every refresh
        /// re-reads it.
        public var helperState = HelperState.notInstalled
        public var helperBusy = false
        public var helperMessage: String?

        public var sslEnabled = false             // M2: HTTPS interception (SSL parsing)
        public var sslScope = SSLScope.disabled   // interception scope (include/exclude globs)
        public var certificateStatus = CertificateStatus.notGenerated
        public var certBusy = false               // a trust action is running
        public var certActionMessage: String?     // transient feedback under the cert card

        /// Origins Loom saw and relayed without reading — excluded, or something it
        /// can't read at any setting. The *only* thing standing between "nothing was
        /// captured for this host" and "nothing happened", because a relayed connection
        /// records no flow at all.
        public var tunneledHosts: [TunneledHost] = []
        /// Dropped past the engine's 256-host cap — surfaced so a truncated list
        /// never reads as a complete one.
        public var tunneledHostsEvicted = 0
        /// Whether the scope editor is open. Collapsed by default, like the
        /// client-certificate section: it earns a row, not permanent space.
        public var sslScopeExpanded = false
        /// A glob the human is typing into the scope editor.
        public var sslScopeDraft = ""
        public var sslScopeMessage: String?
        /// Whether the include/exclude lists are open inside the card.
        ///
        /// Collapsed by default because these lists have the opposite shape to the one
        /// above them: the tunnelled list *shrinks* as hosts get decrypted (a decrypted
        /// host drops out of it), while `exclude` only grows, gaining an entry every
        /// time something breaks. They still have to be reachable — removing an entry is
        /// the only way to start decrypting a host again, and this is the only place an
        /// agent's scope write becomes visible to the human.
        public var sslGlobsExpanded = false

        /// Hosts worth offering a one-click "decrypt" for — the rest are unread for
        /// reasons a scope change can't fix (`notTLSOrHTTP`, a failed leaf mint).
        public var interceptableTunneledHosts: [TunneledHost] {
            tunneledHosts.filter(\.interceptable)
        }

        /// Unread origins the operator did **not** ask for.
        ///
        /// With the default scope decrypting everything, an `excluded` pass-through is
        /// working as configured, and flagging it would train the human to ignore the
        /// flag. What still deserves attention is an origin going unread for a reason
        /// nobody chose — interception switched off, or a host somehow outside a scope
        /// that is meant to cover everything.
        public var unexpectedlyUnreadHosts: [TunneledHost] {
            tunneledHosts.filter { $0.interceptable && $0.reason != .excluded }
        }

        /// Is the scope decrypting everything? The default, and not a problem in
        /// itself — it is the reason a capture is complete out of the box. It only
        /// decides wording: with `*` there is no include list worth reading, so the
        /// summary talks about what is being *passed through* instead.
        public var interceptsEverything: Bool {
            sslScope.enabled && sslScope.include.contains("*")
        }

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
        /// Re-read only the state an *agent* can write: the SSL scope, what it left
        /// tunnelled, and the client identities. Deliberately narrower than
        /// `.refresh` — the helper state and the system-proxy snapshot cost an XPC
        /// round trip and a `SCDynamicStore` read, this fires on every agent write,
        /// and both of those already have live watchers of their own.
        case refreshAgentWritable
        case toggleSystemProxyTapped
        case systemProxyResult(enabling: Bool, ok: Bool, message: String?)
        case systemProxyStateLoaded(Bool)
        /// macOS reported new proxy settings — either someone else changed them, or
        /// our own write landed.
        case systemProxySnapshotChanged(SystemProxySnapshot)
        /// The helper row was tapped: install it, or (once registered) take the human
        /// to the approval switch. Which one it means is decided from `helperState`,
        /// in the reducer, so the view stays a projection.
        case helperRowTapped
        case helperStateLoaded(HelperState, reason: String?)
        case helperActionFinished(state: HelperState, error: String?)
        case toggleSSLTapped
        case certificateStatusLoaded(CertificateStatus)
        case sslScopeLoaded(SSLScope)

        // MARK: SSL scope editing + tunnelled-host discovery
        case sslScopeExpandTapped
        case tunneledHostsLoaded(TunneledHostReport)
        /// Poll tick while the editor is open — the other writer is live traffic, and
        /// a host that showed up a second ago is the one being looked for.
        case tunneledHostsTick
        case interceptHostTapped(String)
        case interceptFinished(host: String, outcome: InterceptOutcome)
        /// "Never decrypt this" from a tunnelled row: moves the host to `exclude` so
        /// it stops being offered. The list is a to-do list; this is how an item
        /// leaves it without being intercepted.
        case excludeHostTapped(String)
        case sslGlobsExpandTapped
        case sslScopeDraftChanged(String)
        /// Add a typed glob to `exclude`. The card's one text field feeds this rather
        /// than `include`, because with the default scope covering everything, adding
        /// an include entry is a no-op — the useful manual edit is carving something
        /// *out* (a corporate mirror, a pinned host, an API called by a Python CLI).
        /// Adding to `include` is still reachable, from a tunnelled row's Decrypt.
        case addExcludeGlobTapped
        case removeIncludeGlobTapped(String)
        case removeExcludeGlobTapped(String)
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
                    // The approval switch lives in System Settings, so the other
                    // writer here is the human in another app — re-read, never cache.
                    await send(.helperStateLoaded(
                        privilegedHelperClient.helperState(),
                        reason: privilegedHelperClient.helperFailureReason()
                    ))
                    await send(.certificateStatusLoaded(proxyClient.certificateStatus()))
                    await send(.sslScopeLoaded(proxyClient.sslScope()))
                    // Loaded whether or not the editor is open: the collapsed row
                    // carries the count, which is what makes an unread origin
                    // discoverable without going looking for it.
                    await send(.tunneledHostsLoaded(proxyClient.tunneledHosts()))
                    // Re-read on every appearance, because the other writer is an
                    // agent: an identity can appear without the human doing anything.
                    await send(.clientCertificatesLoaded(proxyClient.clientCertificates()))
                }

            case .refreshAgentWritable:
                return .run { send in
                    await send(.certificateStatusLoaded(proxyClient.certificateStatus()))
                    await send(.sslScopeLoaded(proxyClient.sslScope()))
                    await send(.tunneledHostsLoaded(proxyClient.tunneledHosts()))
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
                // Silent when the helper is installed and approved; one admin prompt
                // otherwise (see PrivilegedHelperClient.setSystemProxy).
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
                    // No standing claim is stored on a clean success (message nil). The
                    // "QUIC is blocked" note is a fact about the *current* routing, not
                    // feedback about this action, so the panel derives it from
                    // `systemProxyRouting`. Storing it as text is what let it outlive
                    // the state it described: another proxy app would take the setting,
                    // the row would correctly read "in use by 127.0.0.1:8888", and the
                    // note underneath would still be claiming Loom had it and would
                    // restore it on quit.
                    //
                    // A *partial* success does carry a message — the proxy landed but
                    // the root-only QUIC work didn't (authorization declined) — and
                    // that caveat is precisely feedback about this action, so it shows.
                    state.systemProxyMessage = message
                } else {
                    state.isSystemProxy = !enabling // revert the optimistic toggle
                    state.systemProxyMessage = message ?? "System proxy change failed."
                }
                return settle

            // MARK: Privileged helper

            case let .helperStateLoaded(helperState, reason):
                state.helperState = helperState
                switch helperState {
                case .enabled:
                    // Clear a stale "approve it in Settings" line once the human has.
                    state.helperMessage = nil
                case .unresponsive:
                    // Say what XPC said. "Not answering, reinstall it" on its own is a
                    // guess dressed as advice, and the reason is usually the fix.
                    state.helperMessage = reason.map { "Not answering — \($0)." }
                        ?? "Not answering. Tap to reinstall."
                default:
                    break
                }
                return .none

            case .helperRowTapped:
                guard !state.helperBusy else { return .none }
                switch state.helperState {
                case .enabled:
                    // Installed and working — the row's action is to undo it. Turning
                    // it off is not a failure state: the toggle keeps working, it just
                    // asks for a password again.
                    state.helperBusy = true
                    state.helperMessage = "Removing helper…"
                    return .run { send in
                        let result = await privilegedHelperClient.uninstallHelper()
                        await send(.helperActionFinished(state: result.state, error: result.error))
                    }
                case .requiresApproval:
                    // Nothing to retry — only the human can flip that switch. Take
                    // them to it rather than re-registering, which changes nothing.
                    return .run { _ in await privilegedHelperClient.openHelperApproval() }
                case .unresponsive, .notInstalled, .notFound:
                    // `.unresponsive` re-registers rather than doing anything special:
                    // that IS the repair for the state's usual cause (an app update
                    // left launchd pointing at the old binary), and `install()` is
                    // idempotent and prompt-free once approved.
                    state.helperBusy = true
                    state.helperMessage = state.helperState == .unresponsive ? "Repairing helper…" : "Installing helper…"
                    return .run { send in
                        let result = await privilegedHelperClient.installHelper()
                        await send(.helperActionFinished(state: result.state, error: result.error))
                    }
                }

            case let .helperActionFinished(helperState, error):
                state.helperBusy = false
                state.helperState = helperState
                if let error {
                    state.helperMessage = error
                } else if helperState == .requiresApproval {
                    // The expected result of a first install, and the one place the
                    // human has to act. Say where, and open it for them.
                    state.helperMessage = "Allow “Loom” in Login Items to finish."
                    return .run { _ in await privilegedHelperClient.openHelperApproval() }
                } else {
                    state.helperMessage = nil
                }
                return .none

            // MARK: SSL interception

            case .toggleSSLTapped:
                let enabling = !state.sslEnabled
                state.sslEnabled = enabling
                var next = state.sslScope
                next.enabled = enabling
                // First time on with no scope: decrypt everything. A whitelist was
                // tried and rejected as the default — it makes the common case
                // "traffic happened and Loom read none of it" and costs a second run
                // of the client to fix, because the bytes of the first one are gone.
                // The cost of this direction is a client with its own certificate
                // store (a JVM, Python, Go) failing at the client rather than here.
                // Nothing is pre-excluded for it — the failure shows up as a flow with
                // a TLS error, and the pass-through list is how it gets carved out.
                if enabling, next.include.isEmpty { next.include = ["*"] }
                state.sslScope = next
                let scope = next
                return .run { send in
                    await proxyClient.setSSLScope(scope)
                    await send(.certificateStatusLoaded(proxyClient.certificateStatus()))
                    await send(.tunneledHostsLoaded(proxyClient.tunneledHosts()))
                }

            // MARK: SSL scope editing + tunnelled-host discovery

            case .sslScopeExpandTapped:
                state.sslScopeExpanded.toggle()
                state.sslScopeMessage = nil
                guard state.sslScopeExpanded else { return .cancel(id: CancelID.tunneledHostPoll) }
                // Polled only while open, like the breakpoint hold poll: the writer is
                // live traffic, which no stream announces per host.
                return .merge(
                    .run { send in await send(.tunneledHostsLoaded(proxyClient.tunneledHosts())) },
                    .run { send in
                        while !Task.isCancelled {
                            try await Task.sleep(for: .seconds(2))
                            await send(.tunneledHostsTick)
                        }
                    }
                    .cancellable(id: CancelID.tunneledHostPoll, cancelInFlight: true)
                )

            case .tunneledHostsTick:
                return .run { send in await send(.tunneledHostsLoaded(proxyClient.tunneledHosts())) }

            case let .tunneledHostsLoaded(report):
                state.tunneledHosts = report.hosts
                state.tunneledHostsEvicted = report.evicted
                return .none

            case let .interceptHostTapped(host):
                return .run { send in
                    await send(.interceptFinished(host: host, outcome: proxyClient.interceptHost(host)))
                }

            case let .interceptFinished(host, outcome):
                // The write landed in the engine; re-read rather than predicting the
                // resulting scope, because an agent may have edited it in between.
                state.sslScopeMessage = Self.interceptMessage(host: host, outcome: outcome)
                return .run { send in
                    await send(.sslScopeLoaded(proxyClient.sslScope()))
                    await send(.tunneledHostsLoaded(proxyClient.tunneledHosts()))
                }

            case let .excludeHostTapped(host):
                var next = state.sslScope
                next.include.removeAll { $0.lowercased() == host.lowercased() }
                if !next.exclude.contains(where: { $0.lowercased() == host.lowercased() }) {
                    next.exclude.append(host)
                }
                return persist(next, into: &state, message: "\(host) will be passed through untouched.")

            case .sslGlobsExpandTapped:
                state.sslGlobsExpanded.toggle()
                return .none

            case let .sslScopeDraftChanged(text):
                state.sslScopeDraft = text
                return .none

            case .addExcludeGlobTapped:
                let glob = state.sslScopeDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                state.sslScopeDraft = ""
                guard !glob.isEmpty else { return .none }
                var next = state.sslScope
                guard !next.exclude.contains(glob) else {
                    state.sslScopeMessage = "\(glob) is already passed through."
                    return .none
                }
                next.exclude.append(glob)
                // An exclude outranks any include, so a host sitting in both stops
                // being decrypted — and leaving the stale include entry there would
                // have the two lists disagree about the same host.
                next.include.removeAll { $0.lowercased() == glob.lowercased() }
                return persist(next, into: &state, message: nil)

            case let .removeIncludeGlobTapped(glob):
                var next = state.sslScope
                next.include.removeAll { $0 == glob }
                return persist(
                    next, into: &state,
                    message: next.include.isEmpty
                        ? "Nothing is decrypted now. Add a host, or decrypt one from the list above."
                        : nil
                )

            case let .removeExcludeGlobTapped(glob):
                var next = state.sslScope
                next.exclude.removeAll { $0 == glob }
                return persist(next, into: &state, message: nil)

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

    private enum CancelID: Hashable { case tunneledHostPoll }

    /// Write an edited scope through and re-read the tunnelled list against it, so a
    /// host that just became intercepted stops being offered.
    ///
    /// State is updated optimistically *and* re-read: the optimistic half keeps the
    /// editor from lagging a keystroke behind, the re-read is what keeps it honest
    /// when an agent wrote the scope at the same moment.
    private func persist(
        _ scope: SSLScope, into state: inout State, message: String?
    ) -> Effect<Action> {
        state.sslScope = scope
        state.sslEnabled = scope.enabled
        state.sslScopeMessage = message
        return .run { send in
            await proxyClient.setSSLScope(scope)
            await send(.sslScopeLoaded(proxyClient.sslScope()))
            await send(.tunneledHostsLoaded(proxyClient.tunneledHosts()))
        }
    }

    /// What an intercept actually achieved. The `shadowedByExclude` case is the whole
    /// reason this returns prose rather than nothing: the include list will show the
    /// host, which reads as done, while the traffic stays unread.
    static func interceptMessage(host: String, outcome: InterceptOutcome) -> String {
        if let shadow = outcome.shadowedByExclude {
            return "\(host) is included but still passed through — “\(shadow)” excludes it."
        }
        var note = "Decrypting \(host)."
        if outcome.enabledInterception { note += " HTTPS interception is now on." }
        note += " Re-run your client — connections already made are gone."
        return note
    }
}
