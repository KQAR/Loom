import SwiftUI

struct StatusBadge: View {
    let code: Int?
    var body: some View {
        let color = code.map { LoomTheme.statusColor(status: $0, isError: false) } ?? LoomTheme.Palette.error
        CapsuleBadge(
            text: code.map(String.init) ?? "ERR",
            font: .caption.monospacedDigit().weight(.semibold),
            tint: color, hPadding: 7
        )
    }
}
