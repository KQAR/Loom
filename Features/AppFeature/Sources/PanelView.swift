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
                systemProxyRow
                sslRow
                rulesRow

                Divider().padding(.vertical, LoomTheme.Space.xxs)

                PanelRow(
                    kind: .action,
                    icon: "list.bullet.rectangle",
                    title: "Open Main Window",
                    detail: "\(store.status.capturedCount) flows"
                ) {
                    // Capture the popover (the key window at click time) so we can
                    // close it after the main window is up. `dismiss()` alone is
                    // unreliable for a MenuBarExtra window; closing the exact panel
                    // window is deterministic.
                    let panel = NSApp.keyWindow
                    openWindow(id: "main")
                    NSApplication.shared.activate(ignoringOtherApps: true)
                    dismiss()
                    panel?.close()
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

    private var header: some View {
        HStack(spacing: LoomTheme.Space.xs) {
            // Capture state (mirrors the main-window toolbar dot): green when the
            // proxy is up and recording, yellow when up but recording is paused,
            // grey when the proxy is off. Proxy on/off is the switch on the right.
            Circle()
                .fill(captureDotColor)
                .frame(width: 7, height: 7)
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
            detail: store.setup.isSystemProxy ? "on" : "off",
            disabled: store.setup.systemProxyBusy,
            help: "Point macOS's HTTP/HTTPS proxy at Loom (asks for your admin password)"
        ) {
            store.send(.setup(.toggleSystemProxyTapped))
        }
        if store.setup.systemProxyBusy || store.setup.systemProxyMessage != nil {
            inlineNote(store.setup.systemProxyMessage ?? "", busy: store.setup.systemProxyBusy)
        }
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
            VStack(alignment: .leading, spacing: 2) {
                ForEach(store.rules.enabledRules, id: \.self) { rule in
                    Label(rule, systemImage: "checkmark.circle.fill")
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

    private func inlineNote(_ text: String, busy: Bool) -> some View {
        HStack(spacing: LoomTheme.Space.xs) {
            if busy { ProgressView().controlSize(.small) }
            Text(text)
                .font(.caption2)
                .foregroundStyle(.secondary)
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
    /// Optional trailing control that sits outside the row's tap target (e.g. the
    /// proxy row's phone/QR button), so tapping it doesn't also toggle the row.
    var accessory: AnyView? = nil
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

            if let accessory {
                accessory.padding(.trailing, LoomTheme.Space.md)
            }
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
