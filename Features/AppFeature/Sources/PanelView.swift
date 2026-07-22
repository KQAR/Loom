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
                proxyRow
                systemProxyRow
                sslRow
                rulesRow

                Divider().padding(.vertical, LoomTheme.Space.xxs)

                PanelRow(
                    kind: .action,
                    icon: "list.bullet.rectangle",
                    title: "Open Main Window",
                    detail: nil
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
        .frame(width: 300)
        .task { store.send(.viewAppeared) }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: LoomTheme.Space.xs) {
            Circle()
                .fill(store.status.isRunning ? Color.green : Color.secondary)
                .frame(width: 7, height: 7)
            Text("Loom").font(.headline)
            Spacer()
            Text(store.status.isRunning ? "Running" : "Stopped")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, LoomTheme.Space.md)
        .padding(.vertical, LoomTheme.Space.sm)
    }

    // MARK: State rows

    private var proxyRow: some View {
        PanelRow(
            kind: .state(on: store.status.isRunning),
            icon: "network",
            title: "Proxy",
            detail: store.status.isRunning ? "127.0.0.1:\(store.status.port)" : "off"
        ) {
            store.send(.toggleProxyTapped)
        }
    }

    @ViewBuilder private var systemProxyRow: some View {
        PanelRow(
            kind: .state(on: store.isSystemProxy),
            icon: "globe",
            title: "System proxy",
            detail: store.isSystemProxy ? "on" : "off",
            disabled: store.systemProxyBusy,
            help: "Point macOS's HTTP/HTTPS proxy at Loom (asks for your admin password)"
        ) {
            store.send(.toggleSystemProxyTapped)
        }
        if store.systemProxyBusy || store.systemProxyMessage != nil {
            inlineNote(store.systemProxyMessage ?? "", busy: store.systemProxyBusy)
        }
    }

    @ViewBuilder private var sslRow: some View {
        PanelRow(
            kind: .state(on: store.sslEnabled),
            icon: "lock.shield",
            title: "HTTPS (SSL)",
            detail: sslDetail
        ) {
            store.send(.toggleSSLTapped)
        }
        // Cert setup card: only while SSL is on and the CA isn't trusted yet.
        if store.sslEnabled, !store.certificateStatus.trustState.isReady {
            certificateCard
                .padding(.horizontal, LoomTheme.Space.md)
                .padding(.top, LoomTheme.Space.xxs)
        }
    }

    private var sslDetail: String {
        guard store.sslEnabled else { return "off" }
        if store.certificateStatus.isTrusted { return "decrypting" }
        return "CA not trusted"
    }

    @ViewBuilder private var rulesRow: some View {
        PanelRow(
            kind: .state(on: store.rulesEnabled),
            icon: "slider.horizontal.3",
            title: "Rules",
            detail: rulesDetail
        ) {
            store.send(.toggleRulesTapped)
        }
        if !store.enabledRules.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(store.enabledRules, id: \.self) { rule in
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
        guard store.rulesEnabled else { return "off" }
        return store.enabledRules.isEmpty ? "no rules yet" : "\(store.enabledRules.count) active"
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

    // MARK: Certificate setup card

    @ViewBuilder private var certificateCard: some View {
        let state = store.certificateStatus.trustState
        VStack(alignment: .leading, spacing: LoomTheme.Space.sm) {
            HStack(spacing: LoomTheme.Space.sm) {
                Image(systemName: state.systemImageName)
                    .font(.system(size: 13))
                    .foregroundStyle(.orange)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 1) {
                    Text(state.title).font(.callout.weight(.semibold))
                    Text(state.message).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }

            if let fingerprint = store.certificateStatus.sha256Fingerprint {
                Text(fingerprint)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }

            HStack(spacing: LoomTheme.Space.sm) {
                Button {
                    store.send(.installAndTrustCATapped)
                } label: {
                    Label("Install & Trust", systemImage: "checkmark.shield")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(store.certBusy)

                Button("Recheck") { store.send(.recheckCertTapped) }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(store.certBusy)

                Button("Export…") { store.send(.exportCATapped) }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(store.certBusy)
            }

            if store.certBusy {
                HStack(spacing: LoomTheme.Space.xs) {
                    ProgressView().controlSize(.small)
                    Text(store.certActionMessage ?? "Working…").font(.caption2).foregroundStyle(.secondary)
                }
            } else if let message = store.certActionMessage {
                Text(message).font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }

            if let path = store.certificateStatus.exportedPEMPath {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Manual trust:").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                    manualCommand(path: path)
                }
            }
        }
        .padding(LoomTheme.Space.sm)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: LoomTheme.Radius.sm))
    }

    private func manualCommand(path: String) -> some View {
        let command = "sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain \(path)"
        return HStack(alignment: .top, spacing: LoomTheme.Space.xs) {
            Text(command)
                .font(.caption2.monospaced())
                .foregroundStyle(.tertiary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(command, forType: .string)
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .buttonStyle(.borderless)
            .font(.caption2)
            .help("Copy the trust command")
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack {
            Text("\(store.status.capturedCount) flows captured")
                .font(.caption)
                .foregroundStyle(.tertiary)
            Spacer()
            Button("Quit") { NSApplication.shared.terminate(nil) }
                .buttonStyle(.borderless)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, LoomTheme.Space.md)
        .padding(.vertical, LoomTheme.Space.xs + 2)
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
        Button(action: action) {
            HStack(spacing: 0) {
                // Checkmark slot — visible only when a state row is on.
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Color.accentColor)
                    .opacity(isOn ? 1 : 0)
                    .frame(width: 16, alignment: .center)
                    .padding(.trailing, LoomTheme.Space.xs)

                Image(systemName: icon)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .frame(width: 20)
                    .padding(.trailing, LoomTheme.Space.sm)

                Text(title).font(.body)
                Spacer(minLength: LoomTheme.Space.xs)

                if let detail {
                    Text(detail).font(.callout).foregroundStyle(.tertiary)
                }
                if kind == .action {
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .padding(.leading, LoomTheme.Space.xxs)
                }
            }
            .padding(.horizontal, LoomTheme.Space.md)
            .padding(.vertical, LoomTheme.Space.xs)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: LoomTheme.Radius.sm)
                    .fill(Color.accentColor.opacity(hovering && !disabled ? 0.12 : 0))
                    .padding(.horizontal, LoomTheme.Space.xs)
            )
        }
        .buttonStyle(.plain)
        .disabled(disabled)
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
