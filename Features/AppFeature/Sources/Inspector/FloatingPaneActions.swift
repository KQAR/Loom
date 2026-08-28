import AppKit
import SwiftUI

/// How many hits the in-pane find field is sitting over.
/// The cluster shows `current/matchCount` (1-based current) and steps Body,
/// Headers and Cookies.
struct InspectorFindReport: Equatable {
    var matchCount = 0
    static let empty = InspectorFindReport()
}

/// Whether the pane's body is currently rendered as the collapsible JSON tree.
///
/// A preference rather than something each pane works out for itself: the answer
/// depends on the one-shot parse and the tree's size limit, both of which are
/// `BodyView`'s, and a pane that re-derived it would offer an expand control over a
/// raw text pane whenever the two tests drifted.
struct InspectorBodyOutlineKey: PreferenceKey {
    static let defaultValue = false
    static func reduce(value: inout Bool, nextValue: () -> Bool) {
        value = value || nextValue()
    }
}

struct InspectorFindReportKey: PreferenceKey {
    static let defaultValue = InspectorFindReport.empty
    static func reduce(value: inout InspectorFindReport, nextValue: () -> InspectorFindReport) {
        let next = nextValue()
        if next != .empty { value = next }
    }
}

/// Floating search + copy cluster pinned to the top-right of a Body, Headers
/// or Cookies pane. Search reveals an in-pane find field (slides out of the
/// trailing cluster, same ease-out as the table's find bar); copy takes the
/// pane's text and briefly flips to a checkmark.
struct FloatingPaneActions: View {
    let copyText: String
    var copyHelp: String
    @Binding var find: InspectorFind
    var report: InspectorFindReport = .empty
    /// The pane's whole-tree expansion, when the pane has one to offer. Nil for the
    /// Headers and Cookies clusters, and for a body that isn't a tree — a control
    /// that is drawn but does nothing is worse than one that isn't there.
    var expansion: Binding<JSONExpansionCommand>?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var copied = false
    @FocusState private var fieldFocused: Bool

    private var matchCount: Int { report.matchCount }

    var body: some View {
        HStack(spacing: LoomTheme.Space.xs) {
            if find.isPresented {
                findField
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
            paneButton(
                systemImage: "magnifyingglass",
                active: find.isPresented,
                help: "Find"
            ) {
                find.toggle()
            }
            // Second, between Find and Copy: Find is the one control every pane has and
            // the one the find field slides out of, so it stays at the head of the
            // cluster; this is conditional (Body-with-a-tree only), and a conditional
            // control in front of a permanent one moves the permanent one whenever it
            // appears.
            if let expansion {
                paneButton(
                    systemImage: expansion.wrappedValue.isExpandedAll
                        ? "arrow.down.right.and.arrow.up.left"
                        : "arrow.up.left.and.arrow.down.right",
                    active: expansion.wrappedValue.generation > 0,
                    help: expansion.wrappedValue.isExpandedAll ? "Collapse all" : "Expand all"
                ) {
                    if expansion.wrappedValue.isExpandedAll {
                        expansion.wrappedValue.collapseAll()
                    } else {
                        expansion.wrappedValue.expandAll()
                    }
                }
            }
            paneButton(
                systemImage: copied ? "checkmark" : "doc.on.doc",
                active: copied,
                help: copyHelp
            ) {
                WireTextPasteboard.copy(copyText)
                copied = true
            }
        }
        .padding(6)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: LoomTheme.Radius.sm))
        .overlay {
            RoundedRectangle(cornerRadius: LoomTheme.Radius.sm)
                .stroke(.quaternary, lineWidth: 1)
        }
        .padding(LoomTheme.Space.sm)
        // Scoped to the field's presence — a blanket animation would also
        // interpolate the hit count as the reader types.
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: find.isPresented)
        .task(id: copied) {
            guard copied else { return }
            try? await Task.sleep(for: .seconds(1.2))
            copied = false
        }
        .task(id: find.isPresented) {
            guard find.isPresented else { return }
            await Task.yield()
            fieldFocused = true
        }
        .onChange(of: find.needle) { find.currentIndex = 0 }
        .onChange(of: matchCount) { find.clamp(matchCount: matchCount) }
        .onExitCommand {
            if find.isPresented { find.toggle() }
        }
    }

    private var findField: some View {
        HStack(spacing: LoomTheme.Space.xxs) {
            TextField("Find", text: $find.needle)
                .textFieldStyle(.plain)
                .font(.callout)
                .frame(width: 140)
                .focused($fieldFocused)
                .onSubmit { step(by: 1) }
            if find.isActive {
                Text(countLabel)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .fixedSize()
            }
            if matchCount > 0 {
                Button { step(by: -1) } label: {
                    Image(systemName: "chevron.up").font(.caption2.weight(.semibold))
                }
                .buttonStyle(.plain)
                .help("Previous match")
                .accessibilityLabel("Previous match")
                Button { step(by: 1) } label: {
                    Image(systemName: "chevron.down").font(.caption2.weight(.semibold))
                }
                .buttonStyle(.plain)
                .help("Next match")
                .accessibilityLabel("Next match")
            }
        }
    }

    private var countLabel: String {
        matchCount == 0 ? "0" : "\(find.currentIndex + 1)/\(matchCount)"
    }

    private func step(by delta: Int) {
        find.step(by: delta, matchCount: matchCount)
    }

    private func paneButton(
        systemImage: String, active: Bool, help: String, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.callout)
                .foregroundStyle(active ? LoomTheme.Palette.accent : .secondary)
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }
}
