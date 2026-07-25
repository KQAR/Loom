import SwiftUI

struct MethodBadge: View {
    let method: String
    var body: some View {
        CapsuleBadge(text: method, font: .caption.monospaced().weight(.semibold), hPadding: 7)
    }
}
