import SwiftUI

struct HeaderEditor: View {
    let title: String
    @Binding var text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(title) — Name: Value per line").font(.caption).foregroundStyle(.secondary)
            TextEditor(text: $text)
                .font(.callout.monospaced())
                .frame(minHeight: 44)
                .scrollContentBackground(.hidden)
                .padding(4)
                .loomField()
        }
    }
}
