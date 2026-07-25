import SwiftUI

struct InspectorTabStrip<Tab: Hashable>: View {
    let tabs: [(String, Tab)]
    @Binding var selection: Tab

    var body: some View {
        HStack(spacing: LoomTheme.Space.md) {
            ForEach(tabs, id: \.1) { title, tab in
                Button {
                    selection = tab
                } label: {
                    Text(title)
                        .font(.callout.weight(selection == tab ? .semibold : .regular))
                        .foregroundStyle(selection == tab ? Color.primary : Color.secondary)
                        .padding(.vertical, LoomTheme.Space.xs)
                        .overlay(alignment: .bottom) {
                            Rectangle()
                                .fill(selection == tab ? Color.accentColor : .clear)
                                .frame(height: 2)
                        }
                }
                .buttonStyle(.plain)
            }
        }
    }
}
