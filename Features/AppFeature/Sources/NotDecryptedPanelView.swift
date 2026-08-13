import ComposableArchitecture
import LoomSharedModels
import SwiftUI

/// The main-window SSL-scope surface (sidebar → Not Decrypted): every origin Loom
/// saw and relayed without reading, with the one action that changes that.
///
/// **This is where the capture gets chosen**, which is what makes it a panel rather
/// than a warning strip. Since 0.0.27 the scope is a whitelist — nothing is
/// decrypted until a host is named — so "not decrypted" is the ordinary state of
/// every host nobody asked about, and the operator's normal loop is: run the app,
/// come here, decrypt the two hosts they care about, run it again.
///
/// The console's `SSLScopeCard` renders the same list for the menu-bar panel. Both
/// read `tunneledHostsByUrgency` and send the same actions, so neither can develop
/// its own opinion about what an origin's state means or what to do about it.
///
/// One consequence of the whitelist worth stating where the button is: decrypting a
/// host does **not** recover the exchange that put it on this list. Those bytes were
/// relayed. The client has to run again — which is free for a page refresh and
/// impossible for a one-shot callback, and is the accepted cost of not breaking
/// clients that don't trust Loom's CA.
struct NotDecryptedPanelView: View {
    let store: StoreOf<SetupFeature>

    var body: some View {
        VStack(spacing: 0) {
            header
            if let message = store.sslScopeMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, LoomTheme.Space.md)
                    .padding(.bottom, LoomTheme.Space.xs)
            }
            Divider()
            if store.tunneledHosts.isEmpty {
                emptyState.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                list
            }
        }
        // The writer here is live traffic, which no stream announces per host, so the
        // panel polls for as long as it is on screen — `.finish()` ties the effect to
        // this view, so a panel nobody is looking at costs nothing. `.onAppear` alone
        // would leave the list frozen at whatever the moment of opening held, which on
        // the surface someone opens *because* a host is missing is the worst answer.
        .task { await store.send(.watchTunneledHosts).finish() }
    }

    private var header: some View {
        HStack(spacing: LoomTheme.Space.sm) {
            VStack(alignment: .leading, spacing: 1) {
                Text(summaryText).font(.callout)
                Text(scopeText).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: LoomTheme.Space.xs)
        }
        .padding(.horizontal, LoomTheme.Space.md)
        .padding(.vertical, LoomTheme.Space.sm)
    }

    private var summaryText: String {
        let count = store.tunneledHosts.count
        if count == 0 { return "Nothing relayed yet" }
        return "\(count) origin\(count == 1 ? "" : "s") seen, not decrypted"
    }

    /// What the scope currently says, in one line. `interception off` leads because it
    /// makes every row here unactionable — a Decrypt that has to switch a machine-wide
    /// setting on first should say so before it is clicked, not after.
    private var scopeText: String {
        guard store.sslEnabled else { return "HTTPS interception is off — turn it on from the console" }
        if store.interceptsEverything { return "Decrypting all hosts" }
        let count = store.sslScope.include.count
        return count == 0
            ? "No hosts decrypted yet — pick the ones you want to read"
            : "Decrypting \(count) host\(count == 1 ? "" : "s")"
    }

    /// Bounded by the engine's own 256-origin cap, and `List` is lazy over it. What
    /// the cap dropped is counted rather than hidden, same as everywhere else.
    private var list: some View {
        List {
            ForEach(store.tunneledHostsByUrgency) { entry in
                TunneledHostRow(entry: entry) {
                    store.send(.interceptHostTapped(entry.host))
                }
                .listRowSeparator(.hidden)
            }
            if store.tunneledHostsEvicted > 0 {
                Text("\(store.tunneledHostsEvicted) older origin\(store.tunneledHostsEvicted == 1 ? "" : "s") dropped past the 256 Loom keeps")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .listRowSeparator(.hidden)
            }
        }
        .listStyle(.inset)
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("Nothing relayed yet", systemImage: "lock.slash")
        } description: {
            Text("Origins appear here as soon as a client opens an HTTPS connection Loom passed through. Decrypt one to read its traffic — the run that put it here can't be recovered, so the client has to make the request again.")
        }
    }
}

// MARK: - Row

/// One origin, why it is unread, and Decrypt where that would help.
///
/// The reason line comes from `SSLScopeCard.caption(for:)` — one wording, because a
/// row that says "not HTTP or TLS — can't be read" in one window and something else
/// in the other is two answers to the same question.
private struct TunneledHostRow: View {
    let entry: TunneledHost
    let onDecrypt: () -> Void

    var body: some View {
        HStack(spacing: LoomTheme.Space.sm) {
            Image(systemName: SSLScopeCard.glyph(for: entry))
                .font(LoomTheme.Icon.card)
                .foregroundStyle(entry.brokeTheClient ? LoomTheme.Palette.warning : .secondary)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 2) {
                Text(entry.host)
                    .font(.callout.monospaced())
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(SSLScopeCard.caption(for: entry))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                if let detail = entry.detail {
                    Text(detail)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
            }

            Spacer(minLength: LoomTheme.Space.xs)

            // Only where an include entry would change the answer. For a broken origin
            // it would not — the client already refused Loom's certificate, or the
            // codec did — and the row's caption is what says so.
            if entry.interceptable {
                Button("Decrypt") { onDecrypt() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("Decrypt \(entry.host) from now on. Its next request is the first one you'll be able to read.")
            }
        }
        .padding(.vertical, 2)
    }
}
