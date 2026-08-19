import AppKit
import SwiftUI

/// How many hits the in-pane find field is sitting over.
/// The cluster shows `current/matchCount` (1-based current) and steps Body,
/// Headers and Cookies.
struct InspectorFindReport: Equatable {
    var matchCount = 0
    static let empty = InspectorFindReport()
}

struct InspectorFindReportKey: PreferenceKey {
    static let defaultValue = InspectorFindReport.empty
    static func reduce(value: inout InspectorFindReport, nextValue: () -> InspectorFindReport) {
        let next = nextValue()
        if next != .empty { value = next }
    }
}

/// Floating search + copy cluster pinned to the top-right of a Body, Headers
/// or Cookies pane. Search reveals an in-pane find field; copy takes the
/// pane's text and briefly flips to a checkmark.
struct FloatingPaneActions: View {
    let copyText: String
    var copyHelp: String
    @Binding var find: InspectorFind
    var report: InspectorFindReport = .empty

    @State private var copied = false
    @FocusState private var fieldFocused: Bool

    private var matchCount: Int { report.matchCount }

    var body: some View {
        HStack(spacing: LoomTheme.Space.xs) {
            if find.isPresented { findField }
            paneButton(
                systemImage: "magnifyingglass",
                active: find.isPresented,
                help: "Find"
            ) {
                find.toggle()
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
