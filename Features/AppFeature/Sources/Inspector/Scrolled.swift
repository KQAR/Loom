import SwiftUI

/// A plain SwiftUI scroll container with the pane's standard padding — used by
/// every tab that isn't a large text/body (those scroll themselves).
struct Scrolled<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        ScrollView {
            content
                .padding(LoomTheme.Space.md)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
