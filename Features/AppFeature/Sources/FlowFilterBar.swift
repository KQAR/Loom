import ComposableArchitecture
import SwiftUI

/// The main window's find bar: a needle, a scope, and what the current answer is
/// worth. Shown above the request table, hidden until ⌘F.
///
/// **Not in the toolbar**, though `.searchable` would put it there. DESIGN.md
/// § main-window describes that band as a centred chip plus the capture controls, and
/// `MainView.toolbarContent` records what happens when something stretchy joins it
/// under macOS 26: the shared-glass capsule grows with the `.principal` item's
/// padding. A find bar attached to the thing it filters also matches every other
/// traffic inspector, and rides `requestArea`'s existing safe-area insets rather than
/// the titlebar's hand-rolled backdrop.
struct FlowFilterBar: View {
    @Bindable var store: StoreOf<AppFeature>
    @FocusState private var fieldFocused: Bool

    var body: some View {
        HStack(spacing: LoomTheme.Space.xs) {
            Image(systemName: "line.3.horizontal.decrease")
                .font(.caption)
                .foregroundStyle(.secondary)

            // Ahead of the field, because it qualifies what you are about to
            // type rather than the answer you already got — the line reads
            // "search in URL for …" left to right.
            // Same dropdown as the rule editor's (`LoomPicker`): value plus a
            // chevron, no bezel. A pop-up button's bezel is the heaviest thing in a
            // one-line `.bar` strip whose other controls are a plain field and a
            // borderless glyph.
            LoomPicker(
                selection: Binding(
                    get: { store.search.scope },
                    set: { store.send(.searchScopeChanged($0)) }
                ),
                items: FlowSearchScope.allCases.map { ($0, $0.label) },
                font: .callout
            )
            .help("URL is matched here; headers and bodies are matched by the engine")
            .accessibilityLabel("Search in")

            TextField(
                "Filter requests",
                text: Binding(
                    get: { store.search.text },
                    set: { store.send(.searchTextChanged($0)) }
                )
            )
            .textFieldStyle(.plain)
            .font(.callout)
            .focused($fieldFocused)
            .onSubmit { store.send(.searchRefreshRequested) }


            status

            Button {
                store.send(.searchDismissed)
            } label: {
                Image(systemName: "xmark.circle.fill").font(.caption)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .accessibilityLabel("Close filter")
        }
        .padding(.horizontal, LoomTheme.Space.sm)
        .padding(.vertical, LoomTheme.Space.xxs)
        .frame(maxWidth: .infinity)
        .background(.bar)
        // ⌘F with the bar already open means "put me back in the field", which is
        // what every other find bar on this platform does.
        //
        // Deferred by a main-actor hop, and that is load-bearing rather than
        // superstition: assigning `@FocusState` while the bar is still being inserted
        // lands before the field is in the responder chain, so the assignment is lost
        // and AppKit gives key focus to the first focusable control instead — the scope
        // picker. Observed exactly that: ⌘F opened the bar, the picker took the focus
        // ring, and everything typed went into it.
        .task(id: store.search.isPresented) {
            guard store.search.isPresented else { return }
            await Task.yield()
            fieldFocused = true
        }
        .onExitCommand { store.send(.searchDismissed) }
    }

    /// What the result is worth, which is a different question per scope: the URL
    /// scope is live by construction, the engine scopes are a snapshot that the
    /// capture keeps moving past.
    @ViewBuilder private var status: some View {
        if store.search.isSearching {
            ProgressView().controlSize(.small)
        } else if store.search.staleCount > 0 {
            // Never silently stale: an engine-scope answer is not re-run on every
            // capture batch (a body needle would put a disk read per flow on the live
            // path), so the flows it cannot account for are counted and offered.
            Button {
                store.send(.searchRefreshRequested)
            } label: {
                Label(
                    "\(store.search.staleCount) new",
                    systemImage: "arrow.clockwise"
                )
                .font(.caption)
            }
            .buttonStyle(.borderless)
            .help("\(store.search.staleCount) flows captured since this search ran — re-run it")
        } else if store.search.isActive {
            let shown = store.displayFlows.count
            let elsewhere = store.search.outOfWindowMatches
            Text(elsewhere > 0 ? "\(shown) + \(elsewhere) older" : "\(shown)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .help(elsewhere > 0
                    ? """
                    \(shown) shown · \(elsewhere) more matched in stored history, \
                    past the \(AppFeature.State.displayCap) this window keeps. \
                    Ask an agent for those, or narrow the filter.
                    """
                    : "Matching flows")
        }
    }
}

/// ⌘F, as an Edit-menu command rather than a hidden button in the view tree.
///
/// The window is a real window of a real (non-`LSUIElement`) app, so the platform's
/// own place for this is Edit ▸ Find — which also makes the shortcut discoverable
/// instead of folklore, and keeps it working while focus sits in the table.
public struct FlowSearchCommands: Commands {
    let store: StoreOf<AppFeature>

    public init(store: StoreOf<AppFeature>) {
        self.store = store
    }

    public var body: some Commands {
        CommandGroup(after: .textEditing) {
            Section {
                Button("Find in Requests") { store.send(.searchToggled) }
                    .keyboardShortcut("f", modifiers: .command)
            }
        }
    }
}
