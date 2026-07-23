import AppKit
import ComposableArchitecture
import SharedModels
import SwiftUI

/// The QR popover shown from the proxy row's phone button: scan to open Loom's
/// on-device setup page, plus the manual proxy address to enter. See INTERACTION
/// (phone capture) and DESIGN (panel styling).
struct PhoneOnboardingView: View {
    let store: StoreOf<PhoneOnboardingFeature>

    var body: some View {
        VStack(spacing: LoomTheme.Space.sm) {
            header

            if let info = store.info {
                qr(info)
                addressBlock(info)
                fingerprint(info)
                Text("Scan with the phone's camera, or enter the proxy above manually. Same Wi-Fi required.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let error = store.errorMessage {
                errorState(error)
            } else {
                loadingState
            }
        }
        .padding(LoomTheme.Space.md)
        .frame(width: LoomTheme.consoleWidth)
        .task { store.send(.task) }
    }

    private var header: some View {
        HStack(spacing: LoomTheme.Space.xs) {
            Image(systemName: "iphone.gen3")
                .font(LoomTheme.Icon.card)
                .foregroundStyle(.secondary)
            Text("Set up a phone").font(.headline)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private func qr(_ info: PhoneOnboardingInfo) -> some View {
        if let image = NSImage(data: info.qrPNGData) {
            Image(nsImage: image)
                .resizable()
                .interpolation(.none)
                .aspectRatio(contentMode: .fit)
                .frame(width: 180, height: 180)
                .padding(LoomTheme.Space.sm)
                .background(.white, in: RoundedRectangle(cornerRadius: LoomTheme.Radius.md))
        } else {
            // QR generation failed — the URL below is still actionable.
            Label("QR unavailable", systemImage: "qrcode")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 180, height: 180)
        }
    }

    private func addressBlock(_ info: PhoneOnboardingInfo) -> some View {
        VStack(spacing: LoomTheme.Space.xxs) {
            row(label: "Proxy", value: info.proxyAddress)
            row(label: "Setup URL", value: info.provisioningURL.absoluteString)
        }
    }

    private func row(label: String, value: String) -> some View {
        HStack(spacing: LoomTheme.Space.xs) {
            Text(label)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 64, alignment: .leading)
            Text(value)
                .font(.callout.monospaced())
                .textSelection(.enabled)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(value, forType: .string)
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .buttonStyle(.borderless)
            .font(.caption2)
            .help("Copy \(label)")
        }
        .padding(.horizontal, LoomTheme.Space.sm)
        .padding(.vertical, LoomTheme.Space.xs)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: LoomTheme.Radius.sm))
    }

    private func fingerprint(_ info: PhoneOnboardingInfo) -> some View {
        Text("CA SHA-256: \(info.fingerprint)")
            .font(.caption2.monospaced())
            .foregroundStyle(.tertiary)
            .lineLimit(1)
            .truncationMode(.middle)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var loadingState: some View {
        HStack(spacing: LoomTheme.Space.xs) {
            ProgressView().controlSize(.small)
            Text("Opening setup server…").font(.callout).foregroundStyle(.secondary)
        }
        .frame(height: 180)
    }

    private func errorState(_ message: String) -> some View {
        VStack(spacing: LoomTheme.Space.xs) {
            Image(systemName: "exclamationmark.triangle")
                .font(LoomTheme.Icon.card)
                .foregroundStyle(.orange)
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(minHeight: 120)
    }
}
