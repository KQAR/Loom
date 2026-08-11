import LoomSharedModels
import SwiftUI

/// One find/replace row: where it applies + its two flags on the top line, then
/// find over replace. The arrow between the two fields is what says which
/// direction the substitution runs — before, they were two identical boxes whose
/// order was the only clue.
///
/// Picking **Header** reveals a target field. Left blank it is the original
/// behaviour — substitute in every header's value — and that is the blunt one:
/// it also hits any other header that happens to contain the same text. Naming
/// the header is what makes "rewrite this one token" expressible without
/// overwriting the whole header.
struct SubstitutionRow: View {
    @Binding var sub: SubstitutionRule
    let allowURL: Bool
    let onDelete: () -> Void

    private var kinds: [SubstitutionRule.Field.Kind] {
        allowURL ? [.url, .header, .body] : [.header, .body]
    }

    private var kind: Binding<SubstitutionRule.Field.Kind> {
        Binding(
            get: { sub.field.kind },
            // Keep the target across a detour through another field, the same way
            // the route payloads survive one — switching to Body and back must not
            // silently widen the substitution to every header.
            set: { sub.field = SubstitutionRule.Field(kind: $0, headerName: sub.field.headerName ?? lastHeaderName) }
        )
    }

    private var headerName: Binding<String> {
        Binding(
            get: { sub.field.headerName ?? "" },
            set: {
                lastHeaderName = $0.isEmpty ? nil : $0
                sub.field = SubstitutionRule.Field(kind: sub.field.kind, headerName: $0)
            }
        )
    }

    @State private var lastHeaderName: String?

    var body: some View {
        VStack(alignment: .leading, spacing: LoomTheme.Space.xxs) {
            HStack(spacing: LoomTheme.Space.xs) {
                LoomPicker(
                    selection: kind,
                    items: kinds.map { ($0, Self.label($0)) },
                    width: 104
                )
                .accessibilityLabel("Which part of the message to substitute in")

                if sub.field.kind == .header {
                    LoomTextField(text: headerName, prompt: "any header", mono: true)
                        .frame(width: 180)
                        .accessibilityLabel("Header to substitute in; blank means every header")
                        .help("Leave blank to substitute in every header's value")
                }

                ChipToggle(label: "Aa", isOn: sub.caseSensitive, help: "Case-sensitive match") {
                    sub.caseSensitive.toggle()
                }
                ChipToggle(label: ".*", isOn: sub.isRegex, help: "Regex match") {
                    sub.isRegex.toggle()
                }

                Spacer()

                GlyphButton(systemImage: "trash", help: "Remove this substitution",
                            tint: LoomTheme.Palette.error, action: onDelete)
            }
            HStack(spacing: LoomTheme.Space.xs) {
                LoomTextField(text: $sub.match, prompt: "find (e.g. key=12345)", mono: true)
                Image(systemName: "arrow.right")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
                LoomTextField(text: $sub.replacement, prompt: "replace with (e.g. key=54321)", mono: true)
            }
        }
        .padding(LoomTheme.Space.sm)
        .loomSurface(LoomTheme.Surface.card, radius: LoomTheme.Radius.sm)
    }

    private static func label(_ kind: SubstitutionRule.Field.Kind) -> String {
        switch kind {
        case .url: return "URL"
        case .header: return "Header"
        case .body: return "Body"
        }
    }
}
