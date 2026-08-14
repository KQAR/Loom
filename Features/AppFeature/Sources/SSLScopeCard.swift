import ComposableArchitecture
import LoomSharedModels
import SwiftUI

/// The SSL-proxying scope: the whitelist of hosts Loom decrypts, and the one control
/// that adds to it.
///
/// The scope is a **whitelist** — Charles's model, and Proxyman's: `include` starts
/// empty, nothing is decrypted until a host is named. The wide default
/// (`include: ["*"]`) was tried twice and measured twice: it makes Loom terminate TLS
/// for every client on the machine, a connected phone's whole OS included, so an app
/// under test could not be run until its origins had been carved out one at a time —
/// 67 refusing origins in one session. Its cost is that an un-named host's *first*
/// run is unreadable and its bytes are gone.
///
/// **The card used to lead with the origins Loom saw and did not read, and that list
/// is gone from here.** It was the answer to "un-named must not mean invisible" back
/// when a pass-through recorded no flow at all — but the request table answers that
/// now, one `CONNECT` row per relayed connection, with an SSL column and a
/// right-click Decrypt (AGENTS.md § the scope is a whitelist). Keeping it here made
/// this card a second, aggregated rendering of the same origins: a 256-host log
/// showing 6 at a time, in a 300pt console, above the two lines someone opened the
/// card to edit. One surface per question — the table lists origins, this card holds
/// the configuration.
///
/// What that costs, stated rather than discovered: a **refused** origin is no longer
/// one click from a Pass Through here. The row's `N refused` still counts it, and the
/// repair is on its row in the window, where the failure is also visible as an
/// exchange that broke.
struct SSLScopeCard: View {
    let store: StoreOf<SetupFeature>

    /// Whether the add form is showing. View-local like `ReverseProxyCard`'s: it is
    /// the state of a control, not of the scope, and nothing outside this card reads
    /// it.
    @State private var adding = false

    var body: some View {
        VStack(alignment: .leading, spacing: LoomTheme.Space.sm) {
            // The whitelist *is* the configuration under this scope — the answer to
            // "what is Loom reading" — so it is the card's first and main content and
            // is never behind a fold. It used to sit under the tunnelled list and
            // inside the glob disclosure, i.e. behind two of them, and an operator who
            // had just decrypted a host could not find where that had been recorded.
            globSection(
                title: "Decrypting",
                globs: store.sslScope.include,
                empty: "Nothing is decrypted yet. Add a host here, or right-click a relayed row in the main window.",
                remove: { store.send(.removeIncludeGlobTapped($0)) }
            )

            // **Only when it holds something**, which under a whitelist is rare and
            // is the honest reading of what an exclude is *for*: an un-named host is
            // already relayed, so the only carve-out that does anything removal
            // cannot is a hole punched in a glob (`*.corp` covering `api.corp`).
            // Rendering the section empty on every install would give the scope two
            // headings where it has one list, and teach the reader that the second is
            // always blank.
            //
            // Never hidden when non-empty, though: this card is the only surface on
            // which an agent's `set_ssl_scope` becomes visible to the human, and an
            // exclude it wrote has to be readable and removable here.
            if !store.sslScope.exclude.isEmpty {
                globSection(
                    title: "Passed through",
                    globs: store.sslScope.exclude,
                    empty: "",
                    remove: { store.send(.removeExcludeGlobTapped($0)) }
                )
            }

            // Last, under both lists: it adds to whichever one the picker names, so it
            // cannot sit under just one of them without reading as belonging to it.
            if adding {
                addForm
            } else {
                addButton
            }

            if let message = store.sslScopeMessage {
                Text(message)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(LoomTheme.Space.sm)
        .loomSurface(LoomTheme.Surface.card)
    }

    // MARK: Adding

    /// Trailing edge, below the list, glyph only — `ReverseProxyCard`'s add button,
    /// for the same reason: the card's whole content is one list, so the button on it
    /// cannot be adding anything else, and the word was spending width on a fact the
    /// position already gives. The tooltip and the accessibility label still say it.
    private var addButton: some View {
        HStack(spacing: LoomTheme.Space.sm) {
            Spacer(minLength: LoomTheme.Space.xs)
            Button {
                adding = true
            } label: {
                Image(systemName: "plus")
            }
            .buttonStyle(.borderless)
            .font(LoomTheme.Icon.card)
            .accessibilityLabel("Decrypt a host")
            .help("Decrypt a host, or pass one through")
        }
        .frame(maxWidth: .infinity)
    }

    private var addForm: some View {
        VStack(alignment: .leading, spacing: LoomTheme.Space.xs) {
            HStack(spacing: LoomTheme.Space.xs) {
                // Ahead of the field, for the same reason the find bar's scope picker
                // is: it qualifies what you are about to type, so the line reads
                // "Decrypt *.corp.example" left to right. Decrypt leads because it is
                // the primary write — one glob covers a project's whole domain, where
                // the per-row Decrypt is one click *and* one client re-run per
                // sub-domain.
                LoomPicker(
                    selection: Binding(
                        get: { store.sslScopeDraftDecrypts },
                        set: { store.send(.sslScopeDraftTargetChanged($0)) }
                    ),
                    items: [(true, "Decrypt"), (false, "Pass through")],
                    font: .callout
                )
                .accessibilityLabel("What this glob does")

                TextField(
                    "Host or glob, e.g. *.corp.example",
                    text: Binding(
                        get: { store.sslScopeDraft },
                        set: { store.send(.sslScopeDraftChanged($0)) }
                    )
                )
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
                .onSubmit { submit() }
            }

            HStack(spacing: LoomTheme.Space.sm) {
                Spacer(minLength: LoomTheme.Space.xs)
                Button("Cancel") {
                    store.send(.sslScopeDraftChanged(""))
                    adding = false
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button("Add") { submit() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(store.sslScopeDraft.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    private func submit() {
        guard !store.sslScopeDraft.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        store.send(store.sslScopeDraftDecrypts ? .addIncludeGlobTapped : .addExcludeGlobTapped)
        adding = false
    }

    // MARK: Glob lists

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

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
    }

    /// Same cap and same reasoning as `ReverseProxyCard`: the console is a control
    /// surface, not a log. `exclude` in particular only ever grows — it gains an entry
    /// every time something breaks — so it must not be able to grow the panel without
    /// bound, and the whitelist is capped with it rather than trusted to stay short.
    private static let visibleGlobs = 10
}
