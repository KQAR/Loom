import AppKit
import ComposableArchitecture
import SwiftUI

/// The status-bar popover: a compact **config & control console**, not a traffic
/// view. State rows toggle on tap and show a leading checkmark when on; an action
/// row opens the main window in the same style. See DESIGN.md `menu-panel`.
public struct PanelView: View {
    @Bindable var store: StoreOf<AppFeature>
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismiss) private var dismiss

    public init(store: StoreOf<AppFeature>) {
        self.store = store
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            VStack(spacing: 0) {
                devicesRow
                reverseProxyRow
                systemProxyRow
                sslRow
                rulesRow
                breakpointsRow

                Divider().padding(.vertical, LoomTheme.Space.xxs)

                PanelRow(
                    kind: .action,
                    icon: "list.bullet.rectangle",
                    title: "Open Main Window",
                    detail: "\(store.status.capturedCount) flows"
                ) {
                    openMainWindow(at: nil)
                }
            }
            .padding(.vertical, LoomTheme.Space.xs)

            Divider()
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
            // One row, three controls, all centred on the same horizontal line: the
            // capture dot, the address, and the proxy switch. The extra listener lines
            // hang *below* this row rather than sharing it — nesting them in a VStack
            // between the dot and the switch made both drift down to the centre of the
            // whole block, so the top line no longer read as one control strip.
            HStack(spacing: LoomTheme.Space.xs) {
                // Capture state (mirrors the main-window toolbar dot): green when the
                // proxy is up and recording, yellow when up but recording is paused,
                // grey when the proxy is off. Proxy on/off is the switch on the right.
                Circle()
                    .fill(captureDotColor)
                    .frame(width: Self.captureDotSize, height: Self.captureDotSize)
                Text(verbatim: "\(store.displayHost):\(store.status.port)")
                    .font(.headline.monospaced())
                Spacer(minLength: LoomTheme.Space.xs)
                // The proxy on/off control (replaces the old Proxy row + "Running" text).
                Toggle("", isOn: Binding(
                    get: { store.status.isRunning },
                    set: { _ in store.send(.toggleProxyTapped) }
                ))
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
                .help(store.status.isRunning ? "Proxy running — tap to stop" : "Proxy stopped — tap to start")
            }

            VStack(alignment: .leading, spacing: 1) {
                // The second listener, named only when it is actually up. A client
                // that ignores HTTP proxy settings but has a SOCKS field needs this
                // number, and it is not derivable from the one above (the engine
                // fails open if the port was taken).
                if let socksPort = store.status.socksPort {
                    Text(verbatim: "SOCKS5 \(store.displayHost):\(socksPort)")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
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
        .padding(.horizontal, LoomTheme.Space.md)
        .padding(.vertical, LoomTheme.Space.sm)
    }

    /// green = proxy up & recording · yellow = up but recording paused · grey = off.
    private var captureDotColor: Color {
        guard store.status.isRunning else { return .secondary }
        return store.isRecording ? .green : .yellow
    }

    // MARK: State rows

    /// Own row above System proxy: tap to open the phone-onboarding QR; the trailing
    /// number is how many LAN devices (phones/other machines, not this Mac) have
    /// routed traffic through Loom. Needs the proxy up to provision a device.
    private var devicesRow: some View {
        PanelRow(
            kind: .action,
            icon: "iphone",
            // Highlighted (accent) while LAN device connection is allowed, matching
            // the icon's former standalone look; dimmed when off.
            iconTint: store.lanEnabled ? Color.accentColor : .secondary,
            title: "Connect Device",
            detail: "\(store.connectedDeviceCount)",
            disabled: !store.status.isRunning,
            help: "Set up a phone to capture its traffic"
        ) {
            store.send(.phoneButtonTapped(.panel))
        }
        .popover(item: phonePopover, arrowEdge: .trailing) { phoneStore in
            PhoneOnboardingView(store: phoneStore)
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

    @ViewBuilder private var systemProxyRow: some View {
        PanelRow(
            kind: .state(on: store.setup.isSystemProxy),
            icon: "globe",
            title: "System Proxy",
            detail: systemProxyDetail,
            disabled: store.setup.systemProxyBusy,
            help: "Point macOS's HTTP/HTTPS proxy at Loom (asks for your admin password)"
        ) {
            store.send(.setup(.toggleSystemProxyTapped))
        }
        if store.setup.systemProxyBusy || systemProxyNote != nil {
            inlineNote(
                systemProxyNote ?? "",
                busy: store.setup.systemProxyBusy,
                // Tinted only while another app holds the setting: that note is the one
                // the human has to act on (go quit it), unlike the QUIC note, which is
                // just describing a healthy state.
                tint: isSystemProxyOccupied ? .yellow : nil
            )
        }
    }

    /// Another proxy app holds the system proxy. Not the same as off — and while a
    /// change of ours is in flight the note is our own progress text, not this.
    private var isSystemProxyOccupied: Bool {
        guard !store.setup.systemProxyBusy, store.setup.systemProxyMessage == nil else { return false }
        if case .other = store.setup.systemProxyRouting { return true }
        return false
    }

    /// "off" is the wrong word when another proxy app owns the setting: the fix is to
    /// quit Charles, not to press Loom's switch again.
    ///
    /// Kept to two words. The row's detail sits at the trailing edge of a 300pt panel
    /// (`LoomTheme.consoleWidth`) beside the icon and title, so the address does not
    /// fit — it goes in the note underneath, which wraps and is tinted to draw the eye
    /// there anyway.
    private var systemProxyDetail: String {
        switch store.setup.systemProxyRouting {
        case .loom: return "on"
        case .off: return "off"
        case .other: return "in use"
        }
    }

    /// Feedback about the last action if there is any, otherwise a note derived from
    /// where traffic actually goes.
    ///
    /// Derived, not stored: the "QUIC is blocked" line used to be written into
    /// `systemProxyMessage` on a successful enable and never cleared, so when another
    /// proxy app took the setting the row read "in use by 127.0.0.1:8888" while the
    /// line underneath still claimed Loom held it and would restore it on quit. A note
    /// that describes current state has to be a function of current state.
    private var systemProxyNote: String? {
        // A real action's feedback (an error, "Setting system proxy…") outranks the
        // standing note — it is the thing the human just caused and needs to read.
        if store.setup.systemProxyBusy { return store.setup.systemProxyMessage }
        if let message = store.setup.systemProxyMessage { return message }
        switch store.setup.systemProxyRouting {
        case .loom:
            return "QUIC blocked so browser (HTTP/3) traffic is captured. Restored when Loom quits."
        case let .other(host, port):
            // Carries the address the row has no room for, and says what to do rather
            // than only what is wrong: turning Loom on from here works, but it takes
            // the setting and Loom will not hand it back (see AGENTS.md), so quitting
            // the other app first is the safe order.
            return "Another proxy app has it (\(host):\(port)). Quit that app first — Loom won't put its settings back."
        case .off:
            return nil
        }
    }

    /// A way traffic reaches Loom, with Connect Device and System Proxy — and the only
    /// one that needs no cooperation from the client at all, because it looks like the
    /// origin server rather than like a proxy. Sits *above* System Proxy because it is
    /// the one that works when that row can't help: a client which ignores the system
    /// proxy setting (Node's fetch/undici) is exactly who this exists for.
    ///
    /// An **action** row (chevron), never a state row: there is nothing here to toggle
    /// — endpoints are created and removed individually, and the console's only switch
    /// stays the proxy on/off in the header (DESIGN.md). This row and its card are the
    /// **only** place endpoints are reported, agent-created ones included; the caption
    /// lines that used to list them under the header's address are gone.
    @ViewBuilder private var reverseProxyRow: some View {
        PanelRow(
            kind: .action,
            icon: "arrow.left.arrow.right",
            iconTint: reverseProxyIconTint,
            title: "Reverse Proxies",
            detail: reverseProxyDetail,
            help: "Local ports that stand in for an upstream origin — for clients that ignore proxy settings"
        ) {
            store.send(.reverseProxiesExpandTapped)
        }
        if store.reverseProxiesExpanded {
            ReverseProxyCard(store: store)
                .padding(.horizontal, LoomTheme.Space.md)
                .padding(.top, LoomTheme.Space.xxs)
        }
    }

    /// Accent while any endpoint is configured, matching the Connect Device row's
    /// highlight: this is an *action* row, so it has no checkmark slot to say "something
    /// is set up here" and the icon is the only thing that can. Orange outranks it when
    /// one isn't listening — a fault has to read as a fault, not as an active feature.
    private var reverseProxyIconTint: Color? {
        if brokenReverseProxies > 0 { return .orange }
        return store.status.reverseProxies.isEmpty ? nil : Color.accentColor
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

    @ViewBuilder private var sslRow: some View {
        PanelRow(
            kind: .state(on: store.setup.sslEnabled),
            icon: "lock.shield",
            title: "HTTPS (SSL)",
            detail: sslDetail
        ) {
            store.send(.setup(.toggleSSLTapped))
        }
        // Cert setup card: only while SSL is on and the CA isn't trusted yet.
        if store.setup.sslEnabled, !store.setup.certificateStatus.trustState.isReady {
            CertificateTrustCard(store: store.scope(state: \.setup, action: \.setup))
                .padding(.horizontal, LoomTheme.Space.md)
                .padding(.top, LoomTheme.Space.xxs)
        }
        clientCertsRow
    }

    /// Mutual TLS — the identity Loom presents *to* an origin, the mirror of the root
    /// CA above (which is what Loom presents to clients). Sits under the HTTPS row
    /// because it only ever matters while interception is on: with SSL off, HTTPS is
    /// blind-tunneled and Loom never originates the upstream TLS that would present
    /// one.
    ///
    /// Shown while SSL is on, **or** whenever an identity exists — the second half
    /// matters because the other writer is an agent, and an identity installed while
    /// SSL happened to be off would otherwise be an invisible write.
    @ViewBuilder private var clientCertsRow: some View {
        if store.setup.sslEnabled || !store.setup.clientCertificates.isEmpty {
            PanelRow(
                kind: .action,
                icon: "person.badge.key",
                iconTint: store.setup.brokenClientCertificates.isEmpty ? nil : .orange,
                title: "Client Certificates",
                detail: clientCertsDetail,
                help: "Certificates Loom presents when a server demands one (mutual TLS)"
            ) {
                store.send(.setup(.clientCertsExpandTapped))
            }
            if store.setup.clientCertsExpanded {
                ClientCertificatesCard(store: store.scope(state: \.setup, action: \.setup))
                    .padding(.horizontal, LoomTheme.Space.md)
                    .padding(.top, LoomTheme.Space.xxs)
            }
        }
    }

    /// Count, or the broken count when there is one — an expired or unreadable
    /// identity fails a handshake exactly like a missing one, and that is the only
    /// state here the human has to act on.
    private var clientCertsDetail: String {
        let broken = store.setup.brokenClientCertificates.count
        if broken > 0 { return "\(broken) need attention" }
        let total = store.setup.clientCertificates.count
        return total == 0 ? "none" : "\(total)"
    }

    private var sslDetail: String {
        guard store.setup.sslEnabled else { return "off" }
        if store.setup.certificateStatus.isTrusted { return "decrypting" }
        return "CA not trusted"
    }

    @ViewBuilder private var rulesRow: some View {
        PanelRow(
            kind: .state(on: store.rules.rulesEnabled),
            icon: "wand.and.stars",
            title: "Rules",
            detail: rulesDetail
        ) {
            store.send(.rules(.toggleRulesTapped))
        }
        if !store.rules.enabledRules.isEmpty {
            // Capped like the breakpoints row below: the console is a fixed-width
            // popover, and an agent can create rules programmatically — 200 enabled
            // rules must not make the panel 200 rows tall.
            let enabled = store.rules.enabledRules
            VStack(alignment: .leading, spacing: 2) {
                ForEach(enabled.prefix(3), id: \.self) { rule in
                    Label(rule, systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                if enabled.count > 3 {
                    Text("+\(enabled.count - 3) more")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.leading, PanelRow.titleLeadingInset)
            .padding(.horizontal, LoomTheme.Space.md)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var rulesDetail: String {
        guard store.rules.rulesEnabled else { return "off" }
        return store.rules.enabledRules.isEmpty ? "no rules yet" : "\(store.rules.enabledRules.count) active"
    }

    /// Present only when an agent has breakpoints armed or is holding traffic — the
    /// console is a fixed set of rows the rest of the time. Held traffic is a live
    /// client connection stalled by the AI, so it must not be something the human
    /// only discovers by opening the main window and picking the right sidebar row:
    /// it surfaces here in orange, and the row jumps straight to the release surface.
    @ViewBuilder private var breakpointsRow: some View {
        if store.breakpoints.isActive {
            let held = store.breakpoints.heldCount
            PanelRow(
                kind: .action,
                icon: held > 0 ? "pause.circle.fill" : "pause.circle",
                iconTint: held > 0 ? Color.orange : .secondary,
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
                            .foregroundStyle(Color.orange)
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
                .padding(.horizontal, LoomTheme.Space.md)
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

    /// Open the main window (optionally on a given sidebar category) and close the
    /// popover. The key window is captured at click time because `dismiss()` alone
    /// is unreliable for a `MenuBarExtra` window; closing that exact window isn't.
    private func openMainWindow(at category: FlowCategory?) {
        if let category { store.send(.categorySelected(category)) }
        let panel = NSApp.keyWindow
        openWindow(id: "main")
        NSApplication.shared.activate(ignoringOtherApps: true)
        dismiss()
        panel?.close()
    }

    /// `tint == nil` is the ordinary secondary note. A tint is for a note the human is
    /// expected to act on — same yellow as the paused capture dot, which is the panel's
    /// existing "attention, not failure" signal.
    private func inlineNote(_ text: String, busy: Bool, tint: Color? = nil) -> some View {
        HStack(spacing: LoomTheme.Space.xs) {
            if busy { ProgressView().controlSize(.small) }
            Text(text)
                .font(.caption2)
                .foregroundStyle(tint ?? Color.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.leading, PanelRow.titleLeadingInset)
        .padding(.horizontal, LoomTheme.Space.md)
        .frame(maxWidth: .infinity, alignment: .leading)
    }


    // MARK: Footer

    private var footer: some View {
        ZStack {
            // Centered wordmark, independent of the side controls' widths.
            Text("Loom")
                .font(.caption)
                .foregroundStyle(.tertiary)
            HStack {
                updateButton      // version / update, now at the left end
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }
                    .buttonStyle(.borderless)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, LoomTheme.Space.md)
        .padding(.vertical, LoomTheme.Space.xs + 2)
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

/// One tappable console row. State rows show a leading checkmark when on and
/// toggle on tap; action rows show a trailing chevron. Full-width hover highlight
/// (DESIGN `panel-selection`). Replaces the old per-row switch controls.
private struct PanelRow: View {
    enum Kind: Equatable {
        case state(on: Bool)
        case action
    }

    let kind: Kind
    let icon: String
    /// Optional icon tint (e.g. the Connect Device row's accent highlight); the
    /// default secondary is used when nil.
    var iconTint: Color? = nil
    let title: String
    var detail: String?
    var disabled: Bool = false
    var help: String?
    let action: () -> Void

    /// Leading inset of the title = checkmark slot + icon slot + their spacings.
    /// Sub-rows (inline notes, rule list) align to this so they sit under the title.
    static let titleLeadingInset: CGFloat = 16 + LoomTheme.Space.xs + 20 + LoomTheme.Space.sm

    @State private var hovering = false

    private var isOn: Bool {
        if case let .state(on) = kind { return on }
        return false
    }

    var body: some View {
        HStack(spacing: 0) {
            Button(action: action) {
                HStack(spacing: 0) {
                    // Checkmark slot — visible only when a state row is on.
                    Image(systemName: "checkmark")
                        .font(LoomTheme.Icon.badge)
                        .foregroundStyle(Color.accentColor)
                        .opacity(isOn ? 1 : 0)
                        .frame(width: 16, alignment: .center)
                        .padding(.trailing, LoomTheme.Space.xs)

                    Image(systemName: icon)
                        .font(LoomTheme.Icon.card)
                        .foregroundStyle(iconTint ?? .secondary)
                        .frame(width: 20)
                        .padding(.trailing, LoomTheme.Space.sm)

                    Text(title).font(.body)
                    Spacer(minLength: LoomTheme.Space.xs)

                    if let detail {
                        Text(detail).font(.callout).foregroundStyle(.tertiary)
                    }
                }
                .padding(.horizontal, LoomTheme.Space.md)
                .padding(.vertical, LoomTheme.Space.xs)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(disabled)
        }
        .background(
            RoundedRectangle(cornerRadius: LoomTheme.Radius.sm)
                .fill(Color.accentColor.opacity(hovering && !disabled ? 0.12 : 0))
                .padding(.horizontal, LoomTheme.Space.xs)
        )
        .onHover { hovering = $0 }
        .help(help ?? "")
        .accessibilityLabel(title)
        .accessibilityValue(accessibilityValue)
    }

    private var accessibilityValue: String {
        switch kind {
        case let .state(on): return on ? "on" : "off"
        case .action: return ""
        }
    }
}
