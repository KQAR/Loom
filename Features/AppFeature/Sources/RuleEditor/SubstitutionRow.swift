import LoomSharedModels
import SwiftUI

struct SubstitutionRow: View {
    @Binding var sub: SubstitutionRule
    let allowURL: Bool
    let onDelete: () -> Void

    private var fields: [SubstitutionRule.Field] {
        allowURL ? [.url, .header, .body] : [.header, .body]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: LoomTheme.Space.xs) {
                Menu {
                    ForEach(fields, id: \.self) { field in
                        Button(Self.label(field)) { sub.field = field }
                    }
                } label: {
                    HStack(spacing: 3) {
                        Text(Self.label(sub.field)).font(.caption)
                        Image(systemName: "chevron.down").font(.caption2)
                    }
                }
                .menuStyle(.borderlessButton)
                .frame(width: 78)

                iconToggle("Aa", on: sub.caseSensitive, help: "Case-sensitive match") { sub.caseSensitive.toggle() }
                iconToggle(".*", on: sub.isRegex, help: "Regex match") { sub.isRegex.toggle() }

                Spacer()

                Button(role: .destructive, action: onDelete) {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .accessibilityLabel("Remove this substitution")
            }
            TextField("", text: $sub.match, prompt: Text("find (e.g. key=12345)"))
                .textFieldStyle(.roundedBorder)
                .font(.callout.monospaced())
            TextField("", text: $sub.replacement, prompt: Text("replace with (e.g. key=54321)"))
                .textFieldStyle(.roundedBorder)
                .font(.callout.monospaced())
        }
        .padding(LoomTheme.Space.sm)
        .background(.background.opacity(0.4), in: RoundedRectangle(cornerRadius: LoomTheme.Radius.sm))
        .overlay { RoundedRectangle(cornerRadius: LoomTheme.Radius.sm).stroke(.quaternary) }
    }

    private func iconToggle(_ text: String, on: Bool, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(text)
                .font(.caption.monospaced().weight(.bold))
                .foregroundStyle(on ? Color.accentColor : Color.secondary)
                .frame(width: 24, height: 20)
                .background(on ? Color.accentColor.opacity(0.15) : Color.clear, in: RoundedRectangle(cornerRadius: 4))
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private static func label(_ field: SubstitutionRule.Field) -> String {
        switch field {
        case .url: return "URL"
        case .header: return "Header"
        case .body: return "Body"
        }
    }
}
