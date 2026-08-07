import ComposableArchitecture
import LoomSharedModels
import SwiftUI

/// The SSL-proxying scope, and the list of origins Loom saw but did not read.
///
/// One card because they are one decision, read from opposite ends. The default scope
/// decrypts **everything**, so what the human needs here is not "what is covered" —
/// that is "all of it" — but the two ways an origin still ends up unread: something
/// carved out of the scope, and something Loom cannot read whatever the scope says
/// (h2c, SSH, a server-first protocol, a leaf that wouldn't mint). Both are invisible
/// everywhere else, because an unread relay records no flow at all.
///
/// A whitelist default was built and rejected: it makes the common case "traffic
/// happened and Loom read none of it", and fixing that costs a second run of the
/// client because the first run's bytes are gone. So the scope stays wide and this
/// card is where it gets narrowed — one host at a time, driven by what actually
/// broke: a dependency mirror whose JVM rejects Loom's leaf, a pinned host, an API a
/// Python CLI calls. Nothing is pre-excluded; a guessed list would be both incomplete
/// (a corporate mirror is not on it) and quietly wrong (it hides traffic someone may
/// be looking for).
///
/// Lives in the console rather than the main window for the same reason
/// `ClientCertificatesCard` does: per DESIGN v3 the console is the configuration
/// surface. The other writer of this state is an agent (`intercept_host`,
/// `set_ssl_scope`), so the list is the point — a scope an agent narrowed has to be
/// visible and reversible here.
struct SSLScopeCard: View {
    let store: StoreOf<SetupFeature>

    var body: some View {
        VStack(alignment: .leading, spacing: LoomTheme.Space.sm) {
            tunneledSection
            // No hairline between the two halves: the console draws no lines
            // anywhere (DESIGN.md § console), and the disclosure row below is
            // already a distinct shape from the list above it.
            globDisclosure
            if store.sslGlobsExpanded {
                globSection(
                    title: "Passed through",
                    globs: store.sslScope.exclude,
                    empty: "Nothing carved out — every host is decrypted.",
                    remove: { store.send(.removeExcludeGlobTapped($0)) }
                )
                addGlobField
                // Only worth showing when it says something a reader can't already
                // infer: with the default `*` the include list is one line of noise.
                if !store.interceptsEverything {
                    globSection(
                        title: "Decrypting",
                        globs: store.sslScope.include,
                        empty: "Nothing is decrypted. Add a host, or decrypt one from the list above.",
                        remove: { store.send(.removeIncludeGlobTapped($0)) }
                    )
                }
            }

            if let message = store.sslScopeMessage {
                Text(message)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(LoomTheme.Space.sm)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: LoomTheme.Radius.sm))
    }

    // MARK: Seen but not decrypted

    @ViewBuilder private var tunneledSection: some View {
        sectionTitle("Seen, not decrypted")

        if store.tunneledHosts.isEmpty {
            Text("Nothing yet. Origins show up here as soon as a client makes an HTTPS connection Loom passed through.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            // Capped like `ReverseProxyCard`'s list: the remainder is counted rather
            // than rendered, so a busy session can't grow the console panel without
            // bound. Ordered by how much attention the row deserves — something unread
            // that nobody asked for, then the deliberate pass-throughs, then what Loom
            // can't read at any setting.
            let ordered = store.unexpectedlyUnreadHosts
                + store.tunneledHosts.filter { $0.reason == .excluded }
                + store.tunneledHosts.filter { !$0.interceptable }
            ForEach(ordered.prefix(Self.visibleTunneledHosts)) { entry in
                tunneledRow(entry)
            }
            if ordered.count > Self.visibleTunneledHosts {
                Text("+\(ordered.count - Self.visibleTunneledHosts) more")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if store.tunneledHostsEvicted > 0 {
                Text("\(store.tunneledHostsEvicted) older host\(store.tunneledHostsEvicted == 1 ? "" : "s") dropped")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func tunneledRow(_ entry: TunneledHost) -> some View {
        HStack(spacing: LoomTheme.Space.xs) {
            Image(systemName: entry.interceptable ? "lock.slash" : "questionmark.circle")
                .font(LoomTheme.Icon.badge)
                .foregroundStyle(.secondary)
                .frame(width: 14)
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.host)
                    .font(.callout.monospaced())
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(Self.caption(for: entry))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: LoomTheme.Space.xs)
            if entry.interceptable {
                Button("Decrypt") { store.send(.interceptHostTapped(entry.host)) }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("Decrypt \(entry.host) from now on")
                // Only for something unread that *wasn't* asked for: an already-excluded
                // row has nothing to add to the exclude list, and offering it would
                // imply the row is unfinished business when it is the configuration
                // working.
                if entry.reason != .excluded {
                    Button {
                        store.send(.excludeHostTapped(entry.host))
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .help("Never decrypt \(entry.host)")
                }
            }
        }
    }

    /// One line saying why the origin is unread and how much of it there is. Reason
    /// first: it is what decides whether the Decrypt button would do anything.
    static func caption(for entry: TunneledHost) -> String {
        let volume = entry.connections == 1 ? "1 connection" : "\(entry.connections) connections"
        return "\(reason(entry.reason)) · \(volume) · port \(entry.port)"
    }

    private static func reason(_ reason: TunnelReason) -> String {
        switch reason {
        case .interceptionDisabled: "HTTPS interception off"
        case .notInScope: "outside the decrypted scope"
        case .excluded: "passed through on purpose"
        case .noCertificateAuthority: "no root CA yet"
        case .leafMintFailed: "couldn't mint a certificate"
        case .notTLSOrHTTP: "not HTTP or TLS — can't be read"
        }
    }

    // MARK: Glob lists

    /// One line standing in for the two glob lists.
    ///
    /// Collapsed because the lists grow while the list above them shrinks: an
    /// intercepted host drops out of the tunnelled list, whereas `exclude` only
    /// accumulates, gaining one entry every time something breaks. A summary keeps the
    /// card's height roughly constant while leaving the lists one click away, and they
    /// have to *be* reachable: removing an exclude entry is the only way to start
    /// decrypting a host someone carved out, and this card is the only surface on which
    /// an agent's scope write becomes visible.
    private var globDisclosure: some View {
        Button {
            store.send(.sslGlobsExpandTapped)
        } label: {
            HStack(spacing: LoomTheme.Space.xs) {
                Image(systemName: store.sslGlobsExpanded ? "chevron.down" : "chevron.right")
                    .font(LoomTheme.Icon.badge)
                    .foregroundStyle(.secondary)
                    .frame(width: 10)
                Text(globSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("The host globs Loom decrypts, and the ones it deliberately passes through")
    }

    private var globSummary: String {
        let include = store.sslScope.include
        let exclude = store.sslScope.exclude
        // Leads with what is *not* being read, because under the default scope that is
        // the only part carrying information.
        var head: String
        switch exclude.count {
        case 0: head = "Nothing passed through"
        case 1: head = "1 host passed through"
        default: head = "\(exclude.count) hosts passed through"
        }
        if store.interceptsEverything {
            head += " · everything else decrypted"
        } else if include.isEmpty {
            head += " · nothing decrypted"
        } else {
            head += " · \(include.count) decrypted"
        }
        return head
    }

    @ViewBuilder private func globSection(
        title: String, globs: [String], empty: String, remove: @escaping (String) -> Void
    ) -> some View {
        sectionTitle(title)
        if globs.isEmpty {
            if !empty.isEmpty {
                Text(empty)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else {
            // Newest last is how the list is written, so the *end* is what someone
            // who just decrypted a host is looking for — the cap drops from the front
            // and counts what it dropped.
            let hidden = max(0, globs.count - Self.visibleGlobs)
            if hidden > 0 {
                Text("+\(hidden) older, not shown")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            ForEach(globs.suffix(Self.visibleGlobs), id: \.self) { glob in
                HStack(spacing: LoomTheme.Space.xs) {
                    Text(glob)
                        .font(.callout.monospaced())
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: LoomTheme.Space.xs)
                    Button {
                        remove(glob)
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .help("Remove \(glob)")
                }
            }
        }
    }

    private var addGlobField: some View {
        HStack(spacing: LoomTheme.Space.sm) {
            TextField(
                "Pass through a host or glob, e.g. *.corp.example",
                text: Binding(
                    get: { store.sslScopeDraft },
                    set: { store.send(.sslScopeDraftChanged($0)) }
                )
            )
            .textFieldStyle(.roundedBorder)
            .controlSize(.small)
            .onSubmit { store.send(.addExcludeGlobTapped) }

            Button("Add") { store.send(.addExcludeGlobTapped) }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(store.sslScopeDraft.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
    }

    /// Same cap and same reasoning as `ReverseProxyCard`: the console is a control
    /// surface, not a log.
    private static let visibleTunneledHosts = 6

    /// A little more than the tunnelled cap: these lists are opened deliberately, so
    /// the human asked to see them — but `exclude` only grows, so it still must not be
    /// able to grow the panel without bound.
    private static let visibleGlobs = 10
}
