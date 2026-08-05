import ComposableArchitecture
import LoomSharedModels
import SwiftUI
import UniformTypeIdentifiers

/// The mutual-TLS identity list: what Loom presents when an origin demands a client
/// certificate, and the controls to add or remove one.
///
/// Lives in the status-bar console rather than the main window because this is
/// configuration, and per DESIGN v3 the console *is* the configuration surface —
/// the main window is the working surface (table + inspector). It is deliberately
/// **not** a sidebar panel like Rules / Breakpoints / Audit: those exist for
/// activity that needs supervising while it happens, whereas an identity is
/// installed once and then sits there for months.
///
/// It exists at all because an agent can install one over MCP. A capability the
/// human can't see or revoke breaks the half of the contract that says they
/// supervise, so the list is the point and the Add button is the convenience.
struct ClientCertificatesCard: View {
    let store: StoreOf<SetupFeature>

    /// Form state for one import, held in the view on purpose: it is transient, it
    /// dies with the sheet, and one of its fields is a passphrase — the less of that
    /// which lives in shared reducer state, the better.
    @State private var pickedFile: URL?
    @State private var hostPattern = ""
    @State private var passphrase = ""
    @State private var label = ""
    @State private var importing = false
    @State private var pendingDeletion: ClientCertificateSummary?

    var body: some View {
        VStack(alignment: .leading, spacing: LoomTheme.Space.sm) {
            if store.clientCertificates.isEmpty {
                Text("No client certificates. Add one when an origin requires mutual TLS — without it Loom's own connection to that server fails its handshake, so there is nothing to capture.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(store.clientCertificates) { summary in
                    row(summary)
                }
            }

            if let file = pickedFile {
                form(for: file)
            } else {
                HStack(spacing: LoomTheme.Space.sm) {
                    Button {
                        importing = true
                    } label: {
                        Label("Add…", systemImage: "plus")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(store.clientCertBusy)

                    if store.clientCertBusy {
                        ProgressView().controlSize(.small)
                    }
                }
            }

            if let message = store.clientCertMessage {
                Text(message)
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(LoomTheme.Space.sm)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: LoomTheme.Radius.sm))
        .fileImporter(isPresented: $importing, allowedContentTypes: Self.bundleTypes) { result in
            if case let .success(url) = result {
                pickedFile = url
                // Nothing is guessed for the host: presenting a certificate identifies
                // its holder to whoever asked, so the scope has to be typed, not
                // inferred from a filename.
                hostPattern = ""
                passphrase = ""
                label = ""
            }
        }
    }

    // MARK: Rows

    /// One identity. Removal confirms **inline, inside this row** — never in a
    /// `confirmationDialog` or a sheet.
    ///
    /// This card lives in a `MenuBarExtra` popover, and that popover closes the moment it
    /// stops being the key window. A dialog takes key focus to present, so the popover
    /// went away underneath it: the buttons were unclickable, and the orphaned dialog was
    /// still waiting the next time the panel opened. Any presentation that needs its own
    /// window has the same defect here — the fix is to need no second window.
    @ViewBuilder private func row(_ summary: ClientCertificateSummary) -> some View {
        let confirming = pendingDeletion?.id == summary.id
        HStack(alignment: .top, spacing: LoomTheme.Space.sm) {
            Image(systemName: confirming ? "trash" : (summary.problem != nil ? "exclamationmark.triangle.fill" : "person.badge.key"))
                .font(LoomTheme.Icon.badge)
                .foregroundStyle(confirming ? Color.orange : tint(for: summary))
                .frame(width: 14)
            VStack(alignment: .leading, spacing: 1) {
                Text(summary.hostPattern)
                    .font(.callout.monospaced())
                    .lineLimit(1)
                    .truncationMode(.middle)
                if confirming {
                    // Says why this is confirmed at all: the key lives only in Loom's
                    // store, so putting it back means finding the original .p12 again.
                    Text("Handshakes to this host start failing again. You'll need the original .p12 to add it back.")
                        .font(.caption2)
                        .foregroundStyle(Color.orange)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text(caption(for: summary))
                        .font(.caption2)
                        .foregroundStyle(summary.problem != nil || summary.isExpired() ? Color.orange : .secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: LoomTheme.Space.xs)
            if confirming {
                HStack(spacing: LoomTheme.Space.xs) {
                    Button("Cancel") { pendingDeletion = nil }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    Button("Remove") {
                        store.send(.deleteClientCertificateTapped(id: summary.id))
                        pendingDeletion = nil
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .tint(.red)
                    .disabled(store.clientCertBusy)
                }
            } else {
                Button {
                    pendingDeletion = summary
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .font(.caption)
                .disabled(store.clientCertBusy)
                .accessibilityLabel("Remove the certificate for \(summary.hostPattern)")
                .help("Remove this client certificate")
            }
        }
    }

    private func tint(for summary: ClientCertificateSummary) -> Color {
        if summary.problem != nil || summary.isExpired() { return .orange }
        return summary.isEnabled ? .secondary : Color.secondary.opacity(0.5)
    }

    /// One line that answers "will this work". A broken or expired identity fails a
    /// handshake identically to a missing one, so it says so rather than only
    /// printing a date to be compared by eye.
    private func caption(for summary: ClientCertificateSummary) -> String {
        if let problem = summary.problem { return problem }
        if summary.isExpired() {
            return "Expired\(summary.notAfter.map { " \(Self.dateFormatter.string(from: $0))" } ?? "") — handshakes will fail"
        }
        var parts: [String] = []
        if summary.label != summary.hostPattern { parts.append(summary.label) }
        if let subject = summary.subject { parts.append(subject) }
        if let notAfter = summary.notAfter { parts.append("expires \(Self.dateFormatter.string(from: notAfter))") }
        if !summary.isEnabled { parts.append("disabled") }
        return parts.isEmpty ? "installed" : parts.joined(separator: " · ")
    }

    // MARK: Import form

    private func form(for file: URL) -> some View {
        VStack(alignment: .leading, spacing: LoomTheme.Space.xs) {
            Text(file.lastPathComponent)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)

            TextField("Host pattern, e.g. api.corp.example", text: $hostPattern)
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
            SecureField("Passphrase (blank if none)", text: $passphrase)
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
            TextField("Label (optional)", text: $label)
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)

            HStack(spacing: LoomTheme.Space.sm) {
                Button("Add") {
                    store.send(.addClientCertificate(
                        url: file, hostPattern: hostPattern.trimmingCharacters(in: .whitespaces),
                        passphrase: passphrase, label: label.trimmingCharacters(in: .whitespaces)
                    ))
                    reset()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(hostPattern.trimmingCharacters(in: .whitespaces).isEmpty || store.clientCertBusy)

                Button("Cancel") { reset() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
    }

    /// Clears the passphrase along with everything else — it must not survive the
    /// form that collected it.
    private func reset() {
        pickedFile = nil
        hostPattern = ""
        passphrase = ""
        label = ""
    }

    /// `.p12` / `.pfx`. Resolved by extension with a `.data` fallback so a bundle
    /// exported by a tool that set no type is still selectable.
    private static let bundleTypes: [UTType] = {
        let types = ["p12", "pfx"].compactMap { UTType(filenameExtension: $0) }
        return types.isEmpty ? [.data] : types
    }()

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()
}
