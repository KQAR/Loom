import AppKit
import ComposableArchitecture
import SwiftUI

/// The status-bar popover: a compact **config & control console**, not a traffic
/// view. It shows whether the proxy is on, whether Loom is the system proxy, and
/// which rules are active — plus a button to open the main window (the request
/// list lives there). See DESIGN.md `menu-panel`.
public struct PanelView: View {
    @Bindable var store: StoreOf<AppFeature>
    @Environment(\.openWindow) private var openWindow

    public init(store: StoreOf<AppFeature>) {
        self.store = store
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.5)

            VStack(spacing: LoomTheme.Space.sm) {
                proxyRow
                systemProxyRow
                sslRow
                rulesRow
            }
            .padding(LoomTheme.Space.md)

            Divider().opacity(0.5)

            Button {
                openWindow(id: "main")
                NSApplication.shared.activate(ignoringOtherApps: true)
            } label: {
                Label("Open Main Window", systemImage: "list.bullet.rectangle")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(LoomTheme.Space.md)

            Divider().opacity(0.5)
            footer
        }
        .frame(width: 300)
        .task { store.send(.task) }
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

    // MARK: Config rows

    private var proxyRow: some View {
        configRow(
            icon: "network",
            title: "Proxy",
            subtitle: store.status.isRunning ? "127.0.0.1:\(store.status.port)" : "off"
        ) {
            Toggle("", isOn: Binding(
                get: { store.status.isRunning },
                set: { _ in store.send(.toggleProxyTapped) }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)
        }
    }

    @ViewBuilder private var systemProxyRow: some View {
        configRow(
            icon: "globe",
            title: "System proxy",
            subtitle: store.isSystemProxy ? "on · routing all traffic through Loom" : "off · clients use explicit proxy"
        ) {
            Toggle("", isOn: Binding(
                get: { store.isSystemProxy },
                set: { _ in store.send(.toggleSystemProxyTapped) }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)
            .disabled(store.systemProxyBusy)
            .help("Point macOS's HTTP/HTTPS proxy at Loom (asks for your admin password)")
        }
        if store.systemProxyBusy || store.systemProxyMessage != nil {
            HStack(spacing: LoomTheme.Space.xs) {
                if store.systemProxyBusy { ProgressView().controlSize(.small) }
                Text(store.systemProxyMessage ?? "")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.leading, 28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder private var sslRow: some View {
        configRow(
            icon: "lock.shield",
            title: "HTTPS (SSL)",
            subtitle: sslSubtitle
        ) {
            Toggle("", isOn: Binding(
                get: { store.sslEnabled },
                set: { _ in store.send(.toggleSSLTapped) }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)
        }
        // The certificate card guides the human through "generate → trust →
        // decrypt" with one clear next step, shown only while SSL is on and the
        // CA isn't trusted yet.
        if store.sslEnabled, !store.certificateStatus.trustState.isReady {
            certificateCard
        }
    }

    private var sslSubtitle: String {
        guard store.sslEnabled else { return "off · HTTPS blind-tunneled" }
        if store.certificateStatus.isTrusted { return "decrypting · CA trusted" }
        return "on · CA not trusted yet"
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

            // Automatic: one click via the privileged helper. Recheck: re-validate
            // after a manual install. Export…: fall back to the manual path.
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

            // Manual fallback appears once the CA has been exported.
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

    @ViewBuilder private var rulesRow: some View {
        configRow(
            icon: "slider.horizontal.3",
            title: "Rules",
            subtitle: store.enabledRules.isEmpty ? "no rules yet (M3)" : "\(store.enabledRules.count) active"
        ) {
            Text(store.rulesEnabled ? "On" : "Off")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        if !store.enabledRules.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(store.enabledRules, id: \.self) { rule in
                    Label(rule, systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.leading, 28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func configRow(
        icon: String,
        title: String,
        subtitle: String,
        @ViewBuilder trailing: () -> some View
    ) -> some View {
        HStack(spacing: LoomTheme.Space.sm) {
            Image(systemName: icon)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.body)
                Text(subtitle).font(.caption).foregroundStyle(.tertiary)
            }
            Spacer()
            trailing()
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
