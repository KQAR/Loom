import SwiftUI

struct MethodBadge: View {
    let method: String
    var body: some View {
        // `nil` for CONNECT, which is what gives it the neutral capsule — the
        // same split the request table's Method column makes, from the same
        // function, so the badge and the row cannot disagree (`LoomTheme.methodTint`).
        CapsuleBadge(
            text: method,
            font: .caption.monospaced().weight(.semibold),
            tint: LoomTheme.methodTint(method),
            hPadding: 7
        )
    }
}
