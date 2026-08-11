import LoomSharedModels
import SwiftUI

struct SubstitutionListEditor: View {
    @Binding var subs: [SubstitutionRule]
    let allowURL: Bool
    let hint: String

    var body: some View {
        VStack(alignment: .leading, spacing: LoomTheme.Space.sm) {
            HStack(alignment: .top, spacing: LoomTheme.Space.xs) {
                EditorHint(hint)
                Spacer(minLength: LoomTheme.Space.xs)
                GlyphButton(systemImage: "plus", help: "Add a substitution") {
                    subs.append(SubstitutionRule(field: allowURL ? .url : .body, match: "", replacement: ""))
                }
            }

            if subs.isEmpty {
                // Same voice as the rest of the sheet's empty sections: one
                // tertiary line, no illustration, no bordered placeholder box.
                Text("No substitutions yet.").font(.body).foregroundStyle(.tertiary)
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
