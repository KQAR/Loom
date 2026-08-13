import AppKit
import ComposableArchitecture
import SwiftUI

/// The status-bar popover: a compact **config & control console**, not a traffic
/// view.
///
/// Three bands, and which band something lands in is decided by one question —
/// *can its state be read off a three-value tint?* (DESIGN.md § console):
///
/// - **Header** (`PanelGlyphButton`) — the address, the proxy switch, and the
///   bare glyphs that have no state worth a caption: the helper (a property of
///   the listener named right beside it) and the two ways *out* of the console.
/// - **Switch strip** (`PanelTile`) — the three controls that are structurally
///   identical, one boolean each: System Proxy, HTTPS, Rules. A tinted glyph
///   over a caption; the *tint* is the state, in three values.
/// - **Config rows** (`PanelRow`) — everything whose state is a *phrase*:
///   `all but 2 · 3 unread`, `1 need attention`, `2 not listening`. A tint
///   cannot say any of those, so these keep their words. `›` expands a card in
///   place, `↗` leaves the console.
///
/// A three-value tint is a narrow channel, and the **alert channel** between the
/// first two bands is what makes it safe: anything the tint cannot say (which app
/// holds the system proxy, that a helper is waiting on approval) surfaces there,
/// in words, with the repair attached. Without it a warning tile is a dead end —
/// the only thing you can do to it is turn the broken thing off.
public struct PanelView: View {
    @Bindable var store: StoreOf<AppFeature>
    @Environment(\.openWindow) private var openWindow
    @State private var hoveringWordmark = false
    @Environment(\.dismiss) private var dismiss

    public init(store: StoreOf<AppFeature>) {
        self.store = store
    }

    public var body: some View {
        // No dividers and no borders anywhere in this tree: the bands are told
        // apart by their own shapes — a strip of tiles, a list of rows, a strip
        // of glyphs — and by the padding between them. A hairline between two
        // things that already look different is a line that only adds density,
        // and the console's scarcest resource is height.
        VStack(spacing: 0) {
            header
            switchStrip
            alertChannel
            // The CA-trust card is the HTTPS tile's alert line, in richer form:
            // it already names the problem and carries the button that fixes it,
            // so it stands in for a line in the channel above rather than
            // duplicating one.
            if store.setup.sslEnabled, !store.setup.certificateStatus.trustState.isReady {
                CertificateTrustCard(store: store.scope(state: \.setup, action: \.setup))
                    .padding(.horizontal, LoomTheme.consoleMargin)
                    .padding(.top, LoomTheme.Space.xxs)
            }

            VStack(spacing: 0) {
                reverseProxyRow
                sslScopeRow
                clientCertsRow
                breakpointsRow
            }
            .padding(.vertical, LoomTheme.Space.xs)

            footer
        }
        .frame(width: LoomTheme.consoleWidth)
        .task { store.send(.viewAppeared) }
    }

    // MARK: Header

    /// Width of the capture dot, and the indent the extra listener lines hang under
    /// so they start where the address does.
    private static let captureDotSize: CGFloat = 7

    private var header: some View {
        VStack(alignment: .leading, spacing: 1) {
            // One row, everything that is about the listener itself: the capture
            // dot, the address, the helper that makes pointing macOS at it free,
            // the two ways out, and the proxy switch. The extra listener lines
            // hang *below* this row rather than sharing it —
            // nesting them in a VStack between the dot and the switch made both
            // drift down to the centre of the whole block, so the top line no
            // longer read as one control strip.
            HStack(spacing: LoomTheme.Space.xs) {
                // Capture state (mirrors the main-window toolbar dot): green when the
                // proxy is up and recording, yellow when up but recording is paused,
                // grey when the proxy is off. Proxy on/off is the switch on the right.
                Circle()
                    .fill(captureDotColor)
                    .frame(width: Self.captureDotSize, height: Self.captureDotSize)
                Text(verbatim: "\(store.displayHost):\(store.status.port)")
                    .font(.headline.monospaced())
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .layoutPriority(1)
                // Directly after the address because that is what it is about:
                // the helper exists so that pointing macOS at *this* listener
                // stops asking for a password. It is not a switch and it is not a
                // destination, which is why it is the only glyph left up here —
                // a small tinted key, with the two states that need a verb spelled
                // out in the alert channel below.
                helperGlyph
                Spacer(minLength: LoomTheme.Space.xs)
                // The proxy on/off control (replaces the old Proxy row + "Running" text).
                Toggle("", isOn: Binding(
                    get: { store.status.isRunning },
                    set: { _ in store.send(.toggleProxyTapped) }
                ))
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
                // AppKit's switch fills with the *system* accent, which is a hue the
                // user sets and Loom's is not (see `LoomTheme.Palette`). Untinted it
                // sits one row above four tiles wearing Loom's accent for the same
                // meaning — "on" — in a visibly different blue.
                .tint(LoomTheme.Palette.accent)
                .help(store.status.isRunning ? "Proxy running — tap to stop" : "Proxy stopped — tap to start")
            }

            VStack(alignment: .leading, spacing: 1) {
                // The second listener, named only when it is actually up. A client
                // that ignores HTTP proxy settings but has a SOCKS field needs this
                // number, and it is not derivable from the one above (the engine
                // fails open if the port was taken).
                if let socksPort = store.status.socksPort {
                    // Port only, **not** `host:port`. It is always the same host
                    // as the line above — the engine binds both listeners to one
                    // interface — so repeating it made the header look like two
                    // addresses to compare when it is one address with a second
                    // door. The leading indent already aligns this under the host
                    // it belongs to, which is what carries the relationship; the
                    // tooltip has the whole thing for anyone who needs to read it
                    // out. Merging the two into one line was measured and
                    // rejected: at a 20-character LAN address there is no room
                    // left for it, and a line that only sometimes fits is a
                    // layout that jumps.
                    Text(verbatim: "SOCKS5 :\(socksPort)")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .help("SOCKS5 listener on \(store.displayHost):\(socksPort) — for clients that only have a SOCKS field, or set ALL_PROXY")
                }
                // Reverse-proxy endpoints are deliberately NOT listed here, even though
                // they are ports a client gets pointed at like the two above. They have
                // their own row + card now, and that is the one place they are reported
                // — including the ones an agent created. Two copies of a list whose
                // other writer is an agent is two places to keep in step, and the
                // header's copy was the one with no room for the local URL, the
                // upstream, or the Remove button.
            }
            // Indented to the address's leading edge, so the block reads as detail
            // under it rather than as a second column starting at the dot.
            .padding(.leading, Self.captureDotSize + LoomTheme.Space.xs)
        }
        .padding(.horizontal, LoomTheme.consoleMargin)
        .padding(.vertical, LoomTheme.Space.sm)
    }

    /// green = proxy up & recording · yellow = up but recording paused · grey = off.
    private var captureDotColor: Color {
        guard store.status.isRunning else { return .secondary }
        return store.isRecording ? LoomTheme.Palette.success : LoomTheme.Palette.waiting
    }

    // MARK: Switch strip

    /// The three booleans. Nothing else may join them: a control whose state is a
    /// phrase rather than on/off belongs in a config row, which has room to say
    /// the phrase — the caption under each glyph names the control, never what it
    /// is currently doing.
    private var switchStrip: some View {
        // Half the gap the rows use. Four controls that belong to one question
        // should read as one strip, and at Space.xs they read as four separate
        // buttons that happen to be adjacent — the gap was doing the work of a
        // separator on a surface that has none.
        HStack(spacing: LoomTheme.Space.xxs) {
            PanelTile(
                // Deliberately ONE glyph across all three states, and the only
                // control here that doesn't morph. Not for lack of trying: the
                // `globe` family has no fill or slash member, and the `network`
                // alternatives all misstate the fact — `network.slash` says "no
                // network" when what happened is that Charles owns the setting,
                // and `network.badge.shield.half.filled` is unreadable at 18pt. A
                // morph that means the wrong thing is worse than a tint that means
                // the right one, and this switch has the pulse and the alert line
                // carrying its two hard states anyway.
                icon: "globe",
                mode: .systemProxy(store.setup.systemProxyRouting),
                title: "System",
                busy: store.setup.systemProxyBusy,
                disabled: store.setup.systemProxyBusy,
                help: systemProxyHelp
            ) {
                store.send(.setup(.toggleSystemProxyTapped))
            }

            PanelTile(
                icon: httpsIcon,
                mode: .https(
                    sslEnabled: store.setup.sslEnabled,
                    trust: store.setup.certificateStatus.trustState
                ),
                title: "HTTPS",
                help: httpsHelp
            ) {
                store.send(.setup(.toggleSSLTapped))
            }

            PanelTile(
                icon: rulesIcon,
                mode: .rules(enabled: store.rules.rulesEnabled),
                title: "Rules",
                // The only countable switch here, so the only one with a badge:
                // a "1" on a boolean would read as a quantity.
                badge: store.rules.enabledRules.count,
                help: rulesHelp
            ) {
                store.send(.rules(.toggleRulesTapped))
            }

            // The fourth member, and the only one that isn't a switch: it opens
            // the onboarding popover. It sits with the three because it answers
            // the same question they do — how does traffic reach Loom — and it
            // reads the same way, one glyph over one name with a tint saying
            // whether it is live. `toggles: false` is what keeps VoiceOver from
            // calling it "on".
            let device = DeviceReadiness(
                isRunning: store.status.isRunning,
                lanEnabled: store.lanEnabled
            )
            PanelTile(
                // Morphs, not just tints: a phone with radio waves is what "a
                // device can reach this" looks like, a slashed one is what "it
                // can't" looks like, and all three are the same family so
                // `.replace` reads as one becoming the other.
                icon: device.symbol,
                mode: device.isReady ? .on : .off,
                title: "Device",
                badge: store.connectedDeviceCount,
                toggles: false,
                disabled: !store.status.isRunning,
                help: device.help
            ) {
                store.send(.phoneButtonTapped(.panel))
            }
            .popover(item: phonePopover, arrowEdge: .bottom) { phoneStore in
                PhoneOnboardingView(store: phoneStore)
            }
        }
        .padding(.horizontal, LoomTheme.consoleMargin)
        // No band padding at all: each tile already carries its own, the header
        // above ends in whitespace and the rows below start with theirs. Every
        // token added here was counted twice.
    }

    /// Fill = engaged, outline = not. The glyph changes with the state on purpose:
    /// this switch flips **instantly and locally**, so there is nothing to wait
    /// for and nothing to pulse — what it gets instead is a `.replace` transition,
    /// which needs two symbols to be a transition between. Same family, so the
    /// swap reads as one symbol filling in rather than as a different icon.
    ///
    /// The warning state keeps the filled glyph: interception really is on, it is
    /// just not working, and the orange tint is what says so. An outline there
    /// would read as off.
    private var httpsIcon: String {
        store.setup.sslEnabled ? "lock.shield.fill" : "lock.shield"
    }

    /// Same rule as HTTPS — instant toggle, so a two-symbol pair rather than a
    /// pulse. `.inverse` is the filled member of the `wand.and.stars` family.
    private var rulesIcon: String {
        store.rules.rulesEnabled ? "wand.and.stars.inverse" : "wand.and.stars"
    }

    /// Rules on with no rules is deliberately **not** a warning. It is the state
    /// of a fresh install, and an orange tile there would teach the reader to
    /// ignore the colour — the same reason the SSL Scope row's `unread` count
    /// excludes deliberate pass-throughs.
    private var rulesHelp: String {
        guard store.rules.rulesEnabled else { return "Traffic rules are off — tap to enable" }
        let count = store.rules.enabledRules.count
        if count == 0 { return "Rules are on, but none are defined yet — add them in the main window" }
        return "\(count) rule\(count == 1 ? "" : "s") active — tap to disable all"
    }

    private var httpsHelp: String {
        guard store.setup.sslEnabled else { return "HTTPS interception is off — HTTPS is tunnelled blind" }
        return store.setup.certificateStatus.trustState.isReady
            ? "HTTPS interception on — decrypting"
            : "HTTPS interception on, but Loom's root CA isn't trusted yet, so nothing decrypts"
    }

    /// Carries what the tile's fill cannot, in the place a pure-icon control can
    /// still be asked: the QUIC side-effect lives here rather than in a permanent
    /// note under the strip, because it describes a *healthy* state and a healthy
    /// state should not cost a line.
    private var systemProxyHelp: String {
        switch store.setup.systemProxyRouting {
        case .loom:
            return "macOS routes HTTP/HTTPS through Loom. QUIC is blocked so browser (HTTP/3) traffic is captured; both are restored when Loom quits."
        case let .other(host, port):
            return "Another proxy app has the system proxy (\(host):\(port))"
        case .off:
            return store.setup.helperState == .enabled
                ? "Point macOS's HTTP/HTTPS proxy at Loom"
                : "Point macOS's HTTP/HTTPS proxy at Loom (asks for your admin password — install the Privileged Helper to stop that)"
        }
    }

    // MARK: Alert channel

    /// Everything a pure-icon control cannot say. Absent entirely when there is
    /// nothing wrong, which is what pays for the strip above.
    private var alertChannel: some View {
        // Zero-height when both branches are empty, which is the ordinary case —
        // the strip above is only affordable if a healthy console pays nothing
        // for this.
        VStack(spacing: 0) {
            systemProxyAlert
            helperAlert
        }
    }

    /// **Nothing while the change is in flight.** The tile's pulse is the progress
    /// indicator now, and a spinner plus "Setting system proxy…" underneath was
    /// the same fact a second time — on the one surface where a line appearing
    /// and disappearing shoves everything below it. What survives is what the
    /// pulse cannot say: the outcome, and who else holds the setting.
    ///
    /// The in-flight message is suppressed rather than merely out-ranked: it is
    /// written *while* busy, so without the guard it would render as a finished
    /// result — orange triangle and all — for the whole duration.
    @ViewBuilder private var systemProxyAlert: some View {
        if store.setup.systemProxyBusy {
            EmptyView()
        } else if let message = store.setup.systemProxyMessage {
            ConsoleAlertRow(text: message)
        } else if case let .other(host, port) = store.setup.systemProxyRouting {
            // Says what to do rather than only what is wrong: turning Loom on from
            // here works, but it takes the setting and Loom will not hand it back
            // (see AGENTS.md), so quitting the other app first is the safe order.
            // No action — the repair is in that other app, not in Loom.
            ConsoleAlertRow(text: "Another proxy app has the system proxy (\(host):\(port)) — quit it first; Loom won't put its settings back.")
        }
    }

    /// The helper's tool-strip glyph can carry "something is wrong" and no more —
    /// its three states need three different verbs. Only the two states the human
    /// must act on appear here; not-installed is an available option, not a fault.
    @ViewBuilder private var helperAlert: some View {
        if store.setup.helperBusy {
            ConsoleAlertRow(
                text: store.setup.helperMessage ?? "Working on the privileged helper…",
                tint: .secondary,
                busy: true
            )
        } else if let message = store.setup.helperMessage {
            ConsoleAlertRow(
                text: message,
                action: { store.send(.setup(.helperRowTapped)) },
                tint: store.setup.helperState == .requiresApproval ? LoomTheme.Palette.waiting : LoomTheme.Palette.warning
            )
        } else if store.setup.helperState == .requiresApproval {
            ConsoleAlertRow(
                text: "Loom's background helper needs your approval in Login Items.",
                action: { store.send(.setup(.helperRowTapped)) },
                tint: LoomTheme.Palette.waiting
            )
        } else if store.setup.helperState == .unresponsive {
            ConsoleAlertRow(
                text: "The privileged helper stopped answering (usually after an update) — tap to reinstall.",
                action: { store.send(.setup(.helperRowTapped)) }
            )
        }
    }

    // MARK: Config rows

    /// A way traffic reaches Loom, with Connect Device and System Proxy — and the only
    /// one that needs no cooperation from the client at all, because it looks like the
    /// origin server rather than like a proxy. It stays a **row** rather than joining
    /// the header as a bare glyph because its state is a phrase (`2 not listening`), and an
    /// endpoint whose port didn't bind is experienced by its client as connection
    /// refused, i.e. as Loom being down.
    @ViewBuilder private var reverseProxyRow: some View {
        PanelRow(
            kind: .expand(isExpanded: store.reverseProxy.isExpanded),
            icon: store.status.reverseProxies.isEmpty
                ? "arrow.left.arrow.right"
                : "arrow.left.arrow.right.circle.fill",
            iconTint: reverseProxyIconTint,
            title: "Reverse Proxies",
            detail: reverseProxyDetail,
            help: "Local ports that stand in for an upstream origin — for clients that ignore proxy settings"
        ) {
            store.send(.reverseProxy(.expandTapped))
        }
        if store.reverseProxy.isExpanded {
            ReverseProxyCard(store: store.scope(state: \.reverseProxy, action: \.reverseProxy))
                // Leading edge lines up with the row's icon rather than with the panel
                // margin: the card belongs to the row above it, so it must not start
                // further left than anything in it.
                .padding(.leading, LoomTheme.consoleMargin)
                .padding(.trailing, LoomTheme.consoleMargin)
                .padding(.top, LoomTheme.Space.xxs)
        }
    }

    /// Accent while any endpoint is configured: this row's state is otherwise only
    /// in its trailing detail, and the icon is what carries "something is set up
    /// here" at a glance. Orange outranks it when one isn't listening — a fault has
    /// to read as a fault, not as an active feature.
    private var reverseProxyIconTint: Color? {
        if brokenReverseProxies > 0 { return LoomTheme.Palette.warning }
        return store.status.reverseProxies.isEmpty ? nil : LoomTheme.Palette.accent
    }

    /// Endpoints that exist in the config but aren't listening. Their client gets
    /// connection refused, which reads as Loom being down — so the count is surfaced
    /// on the collapsed row rather than waiting to be opened.
    private var brokenReverseProxies: Int {
        store.status.reverseProxies.count { !$0.isListening }
    }

    private var reverseProxyDetail: String {
        let broken = brokenReverseProxies
        if broken > 0 { return "\(broken) not listening" }
        let total = store.status.reverseProxies.count
        return total == 0 ? "none" : "\(total)"
    }

    /// What Loom is *not* decrypting, and what it saw and passed through.
    ///
    /// A row rather than part of the HTTPS tile, because the tile is binary and this
    /// is two lists. Shown while SSL is on **or** whenever something was tunnelled:
    /// an unread origin the human never sees is the failure this exists to remove,
    /// and interception being off is one of the reasons an origin goes unread.
    @ViewBuilder private var sslScopeRow: some View {
        if store.setup.sslEnabled || !store.setup.tunneledHosts.isEmpty {
            PanelRow(
                kind: .expand(isExpanded: store.setup.sslScopeExpanded),
                icon: "list.bullet.rectangle",
                iconTint: store.setup.unexpectedlyUnreadHosts.isEmpty
                    && store.setup.brokenHosts.isEmpty ? nil : LoomTheme.Palette.warning,
                title: "SSL Scope",
                detail: sslScopeDetail,
                help: "Hosts Loom passes through instead of decrypting, and what it saw but couldn't read"
            ) {
                store.send(.setup(.sslScopeExpandTapped))
            }
            if store.setup.sslScopeExpanded {
                SSLScopeCard(store: store.scope(state: \.setup, action: \.setup))
                    .padding(.horizontal, LoomTheme.consoleMargin)
                    .padding(.top, LoomTheme.Space.xxs)
            }
        }
    }

    /// The scope in one phrase, plus anything unread that nobody asked for, plus
    /// anything Loom outright broke.
    ///
    /// Those trailing numbers are the load-bearing half — they are the only hint on a
    /// collapsed console that a capture is thinner than it looks — and `unread`
    /// deliberately counts only the *unexpected* ones: with the default scope covering
    /// everything, an excluded pass-through is the configuration working, and counting
    /// it here would teach the human to ignore the number.
    ///
    /// `refused` is a separate word from `unread` because it is a separate event: an
    /// unread origin's request still reached it, a refused one's never left the
    /// client. Collapsing them would make the console say "3 unread" about traffic
    /// that did not happen. It comes first for the same reason.
    private var sslScopeDetail: String {
        let broken = store.setup.brokenHosts.count
        let unread = store.setup.unexpectedlyUnreadHosts.count
        let head: String
        if store.setup.interceptsEverything {
            let excluded = store.setup.sslScope.exclude.count
            head = excluded == 0 ? "all hosts" : "all but \(excluded)"
        } else {
            let covered = store.setup.sslScope.include.count
            head = covered == 0 ? "none" : "\(covered) host\(covered == 1 ? "" : "s")"
        }
        var flags: [String] = [head]
        if broken > 0 { flags.append("\(broken) refused") }
        if unread > 0 { flags.append("\(unread) unread") }
        return flags.joined(separator: " · ")
    }

    /// Mutual TLS — the identity Loom presents *to* an origin, the mirror of the root
    /// CA (which is what Loom presents to clients). Only matters while interception is
    /// on: with SSL off, HTTPS is blind-tunneled and Loom never originates the upstream
    /// TLS that would present one.
    ///
    /// Shown while SSL is on, **or** whenever an identity exists — the second half
    /// matters because the other writer is an agent, and an identity installed while
    /// SSL happened to be off would otherwise be an invisible write.
    @ViewBuilder private var clientCertsRow: some View {
        if store.setup.sslEnabled || !store.setup.clientCertificates.isEmpty {
            PanelRow(
                kind: .expand(isExpanded: store.setup.clientCertsExpanded),
                icon: store.setup.clientCertificates.isEmpty ? "person.badge.key" : "person.badge.key.fill",
                iconTint: store.setup.brokenClientCertificates.isEmpty ? nil : LoomTheme.Palette.warning,
                title: "Client Certificates",
                detail: clientCertsDetail,
                help: "Certificates Loom presents when a server demands one (mutual TLS)"
            ) {
                store.send(.setup(.clientCertsExpandTapped))
            }
            if store.setup.clientCertsExpanded {
                ClientCertificatesCard(store: store.scope(state: \.setup, action: \.setup))
                    .padding(.horizontal, LoomTheme.consoleMargin)
                    .padding(.top, LoomTheme.Space.xxs)
            }
        }
    }

    /// Count, or the broken count when there is one — an expired or unreadable
    /// identity fails a handshake exactly like a missing one, and that is the only
    /// state here the human has to act on.
    private var clientCertsDetail: String {
        let broken = store.setup.brokenClientCertificates.count
        // Two words, not three: this row's title is the longest in the console,
        // so this string is what decides how narrow the panel can be.
        if broken > 0 { return "\(broken) broken" }
        let total = store.setup.clientCertificates.count
        return total == 0 ? "none" : "\(total)"
    }

    /// Present only when an agent has breakpoints armed or is holding traffic — the
    /// console is a fixed set of rows the rest of the time. Held traffic is a live
    /// client connection stalled by the AI, so it must not be something the human
    /// only discovers by opening the main window and picking the right sidebar row:
    /// it surfaces here in orange, and the row jumps straight to the release surface.
    ///
    /// A row, not a tool-strip glyph: `1 held` and `1 armed` are the same number and
    /// wildly different urgencies, so a badge cannot stand in for the words.
    @ViewBuilder private var breakpointsRow: some View {
        if store.breakpoints.isActive {
            let held = store.breakpoints.heldCount
            PanelRow(
                kind: .navigate,
                icon: held > 0 ? "pause.circle.fill" : "pause.circle",
                iconTint: held > 0 ? LoomTheme.Palette.warning : .secondary,
                title: "Breakpoints",
                detail: breakpointsDetail,
                help: held > 0
                    ? "Traffic is held mid-flight — open Loom to release or abort it"
                    : "Breakpoints armed by your agent"
            ) {
                openMainWindow(at: .breakpoints)
            }
            if held > 0 {
                // Named, not just counted: "2 held" doesn't tell the human whether
                // it's a background poll or the request they're waiting on.
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(store.breakpoints.pending.prefix(3))) { pending in
                        Label("\(pending.method) \(pending.url)", systemImage: "pause.circle.fill")
                            .font(.caption)
                            .foregroundStyle(LoomTheme.Palette.warning)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    if held > 3 {
                        Text("+\(held - 3) more")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.leading, PanelRow.titleLeadingInset)
                .padding(.horizontal, LoomTheme.consoleMargin)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var breakpointsDetail: String {
        let held = store.breakpoints.heldCount
        if held > 0 { return "\(held) held" }
        let armed = store.breakpoints.armed.count
        return "\(armed) armed"
    }

    // MARK: Header glyphs

    private var helperGlyph: some View {
        PanelGlyphButton(
            icon: helperIcon,
            title: "Privileged Helper",
            tint: helperIconTint,
            busy: store.setup.helperBusy,
            disabled: store.setup.helperBusy,
            help: helperHelp
        ) {
            store.send(.setup(.helperRowTapped))
        }
    }

    /// The phone popover, gated to the panel: nil unless the panel opened it, so it
    /// never presents in tandem with the main window's copy of the same state.
    private var phonePopover: Binding<StoreOf<PhoneOnboardingFeature>?> {
        let scoped = $store.scope(state: \.phone, action: \.phone)
        return Binding(
            get: { store.phoneOrigin == .panel ? scoped.wrappedValue : nil },
            set: { scoped.wrappedValue = $0 }
        )
    }

    private var helperIcon: String {
        switch store.setup.helperState {
        case .enabled: return "key.fill"
        case .unresponsive: return "key.slash"
        default: return "key"
        }
    }

    private var helperIconTint: Color? {
        switch store.setup.helperState {
        case .enabled: return LoomTheme.Palette.accent
        case .requiresApproval: return LoomTheme.Palette.waiting
        // Orange, like the broken-client-certificate row: approved but not working is
        // a fault the human can fix, not a state they chose.
        case .unresponsive: return LoomTheme.Palette.warning
        case .notInstalled, .notFound: return .secondary
        }
    }

    /// The label this control doesn't draw. Four states, four verbs — the reason the
    /// two that need action also get a line in the alert channel, where they can be
    /// read without hovering.
    private var helperHelp: String {
        switch store.setup.helperState {
        case .enabled: return "Privileged Helper installed — tap to remove it (the system-proxy toggle will ask for your password again)"
        case .requiresApproval: return "Privileged Helper: open Login Items to allow it"
        case .unresponsive: return "Privileged Helper is approved but not answering (usually after an app update) — tap to reinstall"
        case .notInstalled: return "Install a background helper so toggling the system proxy stops asking for your password"
        case .notFound: return "This build has no helper embedded"
        }
    }

    /// Open the main window (optionally on a given sidebar category) and close the
    /// popover. The key window is captured at click time because `dismiss()` alone
    /// is unreliable for a `MenuBarExtra` window; closing that exact window isn't.
    private func openMainWindow(at category: FlowCategory?) {
        // A single category, replacing whatever the sidebar had: "open the window
        // showing this" is one destination, never something to add to a filter the
        // human set up in another window.
        if let category { store.send(.capture(.categoriesSelected([category]))) }
        let panel = NSApp.keyWindow
        openWindow(id: "main")
        NSApplication.shared.activate(ignoringOtherApps: true)
        dismiss()
        panel?.close()
    }

    // MARK: Footer

    private var footer: some View {
        ZStack {
            wordmarkButton
            HStack {
                updateButton      // version / update, now at the left end
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }
                    .buttonStyle(.borderless)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, LoomTheme.consoleMargin)
        .padding(.vertical, LoomTheme.Space.xs + 2)
    }

    /// The wordmark **is** the way into the main window — glyph and word are one
    /// control, not a button sitting next to a label.
    ///
    /// The glyph takes the wordmark's own `{typography.caption}` rather than a
    /// fixed size, so it reads as a word with a mark in front of it instead of an
    /// icon that happened to be parked there; anything larger and the two stop
    /// being one object. This is the console's highest-frequency action and
    /// deliberately its quietest control: everything above it is configuration
    /// visited rarely, so it earns *position* — the footer is where the eye ends
    /// up anyway — rather than weight.
    private var wordmarkButton: some View {
        Button { openMainWindow(at: nil) } label: {
            HStack(spacing: LoomTheme.Space.xxs) {
                Image(systemName: "macwindow")
                Text("Loom")
            }
            .font(.caption)
            .foregroundStyle(.tertiary)
            .padding(.horizontal, LoomTheme.Space.xs)
            .padding(.vertical, LoomTheme.Space.xxs)
            .background(
                RoundedRectangle(cornerRadius: LoomTheme.Radius.sm)
                    .fill(LoomTheme.Palette.accent.opacity(hoveringWordmark ? LoomTheme.attentionOpacity : 0))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hoveringWordmark = $0 }
        .accessibilityLabel("Open Main Window")
        .help("Open the request list")
    }

    /// Shows the current version as a low-key tap-to-check control; the moment
    /// Sparkle finds a newer release it promotes to a highlighted upgrade icon +
    /// the new version number.
    @ViewBuilder private var updateButton: some View {
        switch store.updateAvailability {
        case let .available(version):
            Button {
                store.send(.checkForUpdatesTapped)
            } label: {
                Label("v\(version)", systemImage: "arrow.up.circle.fill")
                    .font(.caption.weight(.semibold))
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .help("New version \(version) available — click to install")
        case .unknown, .upToDate:
            Button("v\(currentVersion)") { store.send(.checkForUpdatesTapped) }
                .buttonStyle(.borderless)
                .font(.caption)
                .foregroundStyle(.secondary)
                .help("Loom v\(currentVersion) — click to check for updates")
        }
    }

    /// This build's marketing version (`CFBundleShortVersionString`), shown as
    /// the default footer label.
    private var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
    }
}

/// One tappable console row — the band for controls whose state is a *phrase*.
///
/// There is no on/off variant any more: the three booleans moved to the switch
/// strip, so what remains here always resolves to one of two trailing glyphs,
/// and the glyph is the row's only promise about what a tap does. `›` (rotating
/// to `⌄`) expands a card in place; `↗` leaves the console. Before this, action
/// rows drew no trailing glyph at all and were indistinguishable from state
/// rows that happened to be off.
struct PanelRow: View {
    enum Kind: Equatable {
        /// Expands a card directly underneath, in place.
        case expand(isExpanded: Bool)
        /// Leaves the console — opens the main window or another surface.
        case navigate
    }

    let kind: Kind
    let icon: String
    /// Optional icon tint; the default secondary is used when nil.
    var iconTint: Color? = nil
    let title: String
    var detail: String?
    var disabled: Bool = false
    var help: String?
    let action: () -> Void

    /// Leading inset of the title = icon slot + its spacing. Sub-rows (the held
    /// breakpoint list) align to this so they sit under the title.
    static let titleLeadingInset: CGFloat = 20 + LoomTheme.Space.sm

    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            HStack(spacing: 0) {
                Image(systemName: icon)
                    .font(LoomTheme.Icon.card)
                    .foregroundStyle(iconTint ?? .secondary)
                    // Rows morph too where the pair is honest — an outline icon
                    // filling in when the row stops being empty (endpoints,
                    // identities, held traffic). A row's trailing detail already
                    // says the same thing in words, so this is reinforcement, and
                    // it must never be the only place a state appears.
                    .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace))
                    .frame(width: 20)
                    .padding(.trailing, LoomTheme.Space.sm)

                Text(title)
                    .font(.body)
                    // The title never wraps: a row that becomes two lines tall
                    // when a state string grows is the height-jitter this panel
                    // spent a round removing.
                    .lineLimit(1)
                Spacer(minLength: LoomTheme.Space.xs)

                if let detail {
                    Text(detail)
                        .font(.callout)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }

                Image(systemName: trailingGlyph)
                    .font(LoomTheme.Icon.badge)
                    .foregroundStyle(.tertiary)
                    .frame(width: 12)
                    .padding(.leading, LoomTheme.Space.xs)
            }
            .padding(.horizontal, LoomTheme.consoleMargin)
            .padding(.vertical, LoomTheme.Space.xs)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .background(
            RoundedRectangle(cornerRadius: LoomTheme.Radius.sm)
                .fill(LoomTheme.Palette.accent.opacity(hovering && !disabled ? LoomTheme.attentionOpacity : 0))
                .padding(.horizontal, LoomTheme.Space.xs)
        )
        .onHover { hovering = $0 }
        .help(help ?? "")
        .accessibilityLabel(title)
        .accessibilityValue(detail ?? "")
        .accessibilityHint(accessibilityHint)
    }

    private var trailingGlyph: String {
        switch kind {
        case let .expand(isExpanded): return isExpanded ? "chevron.down" : "chevron.right"
        case .navigate: return "arrow.up.right"
        }
    }

    private var accessibilityHint: String {
        switch kind {
        case let .expand(isExpanded): return isExpanded ? "Collapses details" : "Expands details"
        case .navigate: return "Opens the main window"
        }
    }
}
