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

        /// Origins Loom saw and relayed without reading — un-named, excluded, or
        /// something it can't read at any setting.
        ///
        /// **Counted, no longer listed on the console.** The card used to render this
        /// as its lead section; the request table shows the same origins one `CONNECT`
        /// row at a time with the action attached, so what survives here is the two
        /// numbers on the collapsed row (`unexpectedlyUnreadHosts`, `brokenHosts`) —
        /// the only hint on a shut console that a capture is thinner than it looks.
        public var tunneledHosts: [TunneledHost] = []
        /// Dropped past the engine's 256-host cap — surfaced so a truncated list
        /// never reads as a complete one.
        public var tunneledHostsEvicted = 0
        /// Whether the scope editor is open. Collapsed by default, like the
        /// client-certificate section: it earns a row, not permanent space.
        public var sslScopeExpanded = false
        /// A glob the human is typing into the scope editor.
        public var sslScopeDraft = ""
        /// Which list that glob joins. **Decrypt is the default**, which is the whole
        /// difference the whitelist makes: under a wide scope an include entry is a
        /// no-op and this field could only mean "pass through". Now the primary write
        /// is the other one, and typing `*.corp.example` is how a project's whole
        /// domain gets read in one go rather than one sub-domain per click.
        public var sslScopeDraftDecrypts = true
        public var sslScopeMessage: String?

        /// Hosts worth offering a one-click "decrypt" for — the rest are unread for
        /// reasons a scope change can't fix (`notTLSOrHTTP`, a failed leaf mint).
        public var interceptableTunneledHosts: [TunneledHost] {
            tunneledHosts.filter(\.interceptable)
        }

        /// Unread origins the operator did **not** ask for.
        ///
        /// Which reasons count **depends on the scope**, and getting that wrong makes
        /// this number worthless in one direction or the other.
        ///
        /// An `excluded` pass-through was asked for under any scope. `notInScope` is
        /// the ordinary state of every host nobody named under a whitelist — counting
        /// it puts a permanent "67 unread" on the console, which is the "teach the
        /// human to ignore the number" failure with a new cause — but means the
        /// opposite under a wildcard include, where a host escaping a scope meant to
        /// cover everything is a real anomaly.
        ///
        /// What is left under a whitelist is interception switched off entirely while
        /// traffic arrives: the one case where the operator's *stated* intent and what
        /// Loom is doing disagree.
        public var unexpectedlyUnreadHosts: [TunneledHost] {
            tunneledHosts.filter { entry in
                guard entry.interceptable, entry.reason != .excluded else { return false }
                if entry.reason == .notInScope, !interceptsEverything { return false }
                return true
            }
        }

        /// Origins whose traffic **failed**, as opposed to merely going unread.
        ///
        /// Every other entry in `tunneledHosts` is a pass-through: the request
        /// reached the origin and Loom simply didn't read it. A refused handshake or
        /// a rejected codec is the one where the request never happened — the
        /// operator's client is broken *because Loom is in the path* — so it is the
        /// most urgent thing this list can hold.
        ///
        /// It is deliberately not folded into `unexpectedlyUnreadHosts`: that one
        /// asks "would decrypting this host help", and the answer here is no (these
        /// are `interceptable == false`, which is why they went uncounted for four
        /// releases while `TunneledHost.brokeTheClient` sat unused). The two need
        /// different words on every surface — unread means Loom saw less than it
        /// could, broken means the client saw nothing at all.
        public var brokenHosts: [TunneledHost] {
            tunneledHosts.filter(\.brokeTheClient)
        }

        /// Is the scope decrypting everything? **Not the default** — the scope is a
        /// whitelist — but one deliberate setting away, and two surfaces read it: with
        /// `*` there is no include list worth reading, so the summary talks about what
        /// is being *passed through* instead, and `notInScope` flips from "the ordinary
        /// state of an un-named host" to "a host escaped a scope meant to cover
        /// everything" (see `unexpectedlyUnreadHosts`).
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
        /// Re-write the system proxy setting at the current port — sent by the parent
        /// after a rebind, because the setting holds a port and would otherwise
        /// address a listener that has moved.
        case reapplySystemProxy
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
        /// "Never decrypt this" — from a tunnelled row on the console, and from a
        /// captured row's context menu in the main window. Moves the host (or a glob
        /// standing for a whole domain) to `exclude`, which is the one write that
        /// stops decryption under a scope that otherwise covers everything.
        ///
        /// One action for both surfaces on purpose: the window is where the operator
        /// *meets* the failure — a request that broke because Loom terminated its TLS
        /// — and the console is where the resulting carve-out is read back. They must
        /// not be able to disagree about what "pass this through" does.
        case excludeHostTapped(String)
        case stopInterceptFinished(host: String, outcome: StopInterceptOutcome)
        case sslScopeDraftChanged(String)
        /// Add a typed glob to `exclude`. The card's one text field feeds this rather
        /// than `include`, because with the default scope covering everything, adding
        /// an include entry is a no-op — the useful manual edit is carving something
        /// *out* (a corporate mirror, a pinned host, an API called by a Python CLI).
        /// Adding to `include` is still reachable, from a tunnelled row's Decrypt.
        case addExcludeGlobTapped
        /// Add the typed glob to `include`. A separate action from its opposite rather
        /// than a parameter: they are different writes with different failure modes
        /// (an include can be shadowed by an exclude; an exclude can't be shadowed by
        /// anything), and each says so in its own message.
        case addIncludeGlobTapped
        case sslScopeDraftTargetChanged(Bool)
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

            case .reapplySystemProxy:
                // The proxy rebound on a new port. The system setting holds the old
                // one, so it now points at nothing; writing it again is what keeps
                // "system proxy: on" true rather than merely displayed.
                guard state.isSystemProxy, state.proxyRunning else { return .none }
                state.systemProxyBusy = true
                let reapplyPort = state.port
                return .run { send in
                    let outcome = await privilegedHelperClient.setSystemProxy(true, reapplyPort)
                    await send(.systemProxyResult(enabling: true, ok: outcome.ok, message: outcome.message))
                }

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
                // Nothing is seeded. The switch means "Loom may decrypt the hosts I
                // name", not "decrypt everything" — Charles's model, and Proxyman's.
                //
                // The alternative shipped in this project twice and was measured
                // twice: seeding `["*"]` makes Loom terminate TLS for every client on
                // the machine, a connected phone's whole OS included, so an app under
                // test could not be run until its origins had been carved out one at a
                // time (67 refusing origins in one measured session). Its cost is
                // stated rather than hidden: an un-named host's *first* run is
                // unreadable and its bytes are gone, so a one-shot request — a login,
                // a callback, a webhook — has to be triggered again after decrypting.
                //
                // What makes that liveable is that un-named is never invisible: every
                // relayed origin is a CONNECT row in the request table and an entry in
                // `tunneledHosts`, and both offer Decrypt.
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
                // **Atomic in the engine, not a local edit + full-scope write.** The
                // old path read `state.sslScope`, called `stopIntercepting` on the
                // copy and wrote the whole scope back through `setSSLScope`; a
                // concurrent agent `intercept_host` (itself atomic via `mutate`)
                // landing between the read and the write was silently clobbered. The
                // whitelist semantics — remove the include entry, add an exclude only
                // when a glob still shadows it — live in `SSLScope.stopIntercepting`,
                // which the engine now runs under the config lock.
                return .run { send in
                    await send(.stopInterceptFinished(host: host, outcome: proxyClient.stopInterceptingHost(host)))
                }

            case let .stopInterceptFinished(host, outcome):
                // The write landed in the engine; re-read rather than predicting the
                // resulting scope, because an agent may have edited it in between —
                // the same shape as `interceptFinished`.
                if outcome.removedIncludes.isEmpty, !outcome.addedExclude {
                    // Neither list changed: the scope already relayed this host.
                    state.sslScopeMessage = "\(host) is already passed through."
                } else {
                    state.sslScopeMessage = Self.excludeMessage(host: host, outcome: outcome)
                }
                return .run { send in
                    await send(.sslScopeLoaded(proxyClient.sslScope()))
                    await send(.tunneledHostsLoaded(proxyClient.tunneledHosts()))
                }

            case let .sslScopeDraftChanged(text):
                state.sslScopeDraft = text
                return .none

            case let .sslScopeDraftTargetChanged(decrypts):
                state.sslScopeDraftDecrypts = decrypts
                return .none

            case .addIncludeGlobTapped:
                let glob = state.sslScopeDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                state.sslScopeDraft = ""
                guard !glob.isEmpty else { return .none }
                var next = state.sslScope
                // Turning the switch on is part of the ask: a glob added while
                // interception is off is a setting that silently does nothing.
                next.enabled = true
                // Case-insensitively, because DNS is and nothing normalizes what
                // someone typed — and the message has to be the *outcome*, not a
                // repeat of the success sentence, or a second Add on the same host
                // reads as having done something.
                guard !next.include.contains(where: { $0.lowercased() == glob.lowercased() }) else {
                    // Still persisted rather than returned early: the entry was
                    // already there, but `enabled` above may be the part that changed,
                    // and dropping the write would leave the switch off with a list
                    // saying the host is decrypted.
                    return persist(next, into: &state, message: "\(glob) is already decrypted.")
                }
                next.include.append(glob)
                // The mirror of the exclude path below: a stale exclude for the same
                // pattern would beat the entry just added, so the two lists would
                // disagree about a host the human just asked to read.
                next.exclude.removeAll { $0.lowercased() == glob.lowercased() }
                return persist(next, into: &state, message: Self.addIncludeMessage(glob: glob, scope: next))

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

    /// What a typed include glob will and won't cover.
    ///
    /// The one case worth a sentence is a wildcard `exclude` that still shadows it —
    /// the same trap `intercept_host` reports as `effective: false`. The include list
    /// will show the glob, which reads as done, while the traffic stays unread.
    static func addIncludeMessage(glob: String, scope: SSLScope) -> String {
        if let shadow = scope.exclude.first(where: { Glob.matches($0, glob) }) {
            return "\(glob) is included but still passed through — “\(shadow)” excludes it."
        }
        return "Decrypting \(glob). Open relayed connections matching this scope are closed, so the client will reconnect — trigger the request again."
    }

    /// What a carve-out achieved, and — the load-bearing half — what it did *not*.
    ///
    /// Two things operators hit as "I clicked it and nothing changed", and the caveat
    /// answers both: this decides how the **next** connection is treated, so a
    /// connection the client already holds keeps the treatment it was opened under,
    /// and the exchange that made someone reach for this is already over.
    ///
    /// The `shadowedByInclude` case is why this is prose rather than one sentence:
    /// dropping the entry was not enough, so an exclude now stands that a later
    /// "decrypt this host" would have to undo.
    static func excludeMessage(host: String, outcome: StopInterceptOutcome) -> String {
        let caveat = "Takes effect on the client's next connection — re-run it."
        if let glob = outcome.shadowedByInclude {
            return "\(host) is passed through, but “\(glob)” still decrypts it — added a carve-out to win. \(caveat)"
        }
        return "\(host) is no longer decrypted. \(caveat)"
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
        // The second half is what operators hit as "I clicked it and nothing changed":
        // the exchange that put the host on the list is gone, and a connection the
        // client already holds would keep its old treatment until it closed. Closing
        // those is what makes the next sentence "trigger it again" rather than
        // "restart your app" — say so, because a client reconnecting on its own is
        // otherwise indistinguishable from nothing having happened.
        if outcome.closedTunnels > 0 {
            let n = outcome.closedTunnels
            note += " Closed \(n) open connection\(n == 1 ? "" : "s") to it, so the client will reconnect."
        }
        note += " Trigger the request again — the exchange that led you here is gone."
        return note
    }
}
