import LoomSharedModels
import SwiftUI

struct SubstitutionListEditor: View {
    @Binding var subs: [SubstitutionRule]
    let allowURL: Bool
    let hint: String

    var body: some View {
        VStack(alignment: .leading, spacing: LoomTheme.Space.sm) {
            HStack {
                Text(hint).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button {
                    subs.append(SubstitutionRule(field: allowURL ? .url : .body, match: "", replacement: ""))
                } label: {
                    Label("Add", systemImage: "plus")
                }
                .controlSize(.small)
            }

            if subs.isEmpty {
                Text("No substitutions yet.").font(.callout).foregroundStyle(.tertiary)
            } else {
                ForEach($subs) { $sub in
                    SubstitutionRow(sub: $sub, allowURL: allowURL) {
                        subs.removeAll { $0.id == sub.id }
                    }
                }
            }
        }
    }
}
