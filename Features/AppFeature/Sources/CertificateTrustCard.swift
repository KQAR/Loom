import AppKit
import ComposableArchitecture
import LoomSharedModels
import SwiftUI

/// The root-CA install-&-trust card. Shared by the status-bar panel (shown while
/// SSL is on and the CA isn't trusted yet) and the main-window toolbar's SSL
/// button popover, so the "quick install & trust" flow is identical in both.
struct CertificateTrustCard: View {
    let store: StoreOf<SetupFeature>

    var body: some View {
        let state = store.certificateStatus.trustState
        VStack(alignment: .leading, spacing: LoomTheme.Space.sm) {
            HStack(spacing: LoomTheme.Space.sm) {
                Image(systemName: state.systemImageName)
                    .font(LoomTheme.Icon.card)
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
}
