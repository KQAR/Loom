import SwiftUI

/// Body editor with Edit/Preview toggle and a Format action. Preview renders the
/// collapsible, syntax-highlighted `JSONView`; Format pretty-prints in place while
/// preserving key order.
struct JSONBodyEditor: View {
    let title: String
    @Binding var text: String
    @State private var showPreview = false

    private var parsed: JSONValue? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return JSONValue.parse(Data(trimmed.utf8))
    }

    var body: some View {
        // One parse per body evaluation: `body` re-runs per keystroke of the
        // bound TextEditor, and reading the computed `parsed` in two places
        // re-parsed the whole body twice per character typed.
        let parsed = self.parsed
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: LoomTheme.Space.xs) {
                Text(title).font(.caption).foregroundStyle(.secondary)
                Spacer()
                if parsed != nil {
                    Button("Format") { if let json = parsed { text = json.prettyPrinted() } }
                        .buttonStyle(.borderless).controlSize(.small)
                    Picker("", selection: $showPreview) {
                        Text("Edit").tag(false)
                        Text("Preview").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 130)
                } else if !text.isEmpty {
                    Text("not JSON").font(.caption2).foregroundStyle(.tertiary)
                }
            }

            if showPreview, let json = parsed {
                ScrollView {
                    JSONView(value: json)
                        .padding(LoomTheme.Space.sm)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(minHeight: 120, maxHeight: 260)
                .loomField()
            } else {
                TextEditor(text: $text)
                    .font(.callout.monospaced())
                    .frame(minHeight: 96)
                    .scrollContentBackground(.hidden)
                    .padding(4)
                    .loomField()
            }
        }
    }
}
