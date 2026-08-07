import SwiftUI

struct MethodBadge: View {
    let method: String
    var body: some View {
        // `nil` for the safe methods, which is what gives them the neutral capsule —
        // the same split the request table's Method column makes, from the same
        // function, so the badge and the row cannot disagree about whether replaying
        // this would change anything (`LoomTheme.methodColor`).
        CapsuleBadge(
            text: method,
            font: .caption.monospaced().weight(.semibold),
            tint: LoomTheme.mutatingMethodColor(method),
            hPadding: 7
        )
    }
}
