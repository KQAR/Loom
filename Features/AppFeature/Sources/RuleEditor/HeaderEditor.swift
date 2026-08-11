import SwiftUI

/// Headers as `Name: Value` lines. The format hint sits in the label rather than
/// as a second line of copy under the box — it is part of what the field *is*,
/// not an explanation of it.
struct HeaderEditor: View {
    let title: String
    @Binding var text: String

    var body: some View {
        LabeledField("\(title) — one Name: Value per line") {
            LoomTextArea(text: $text, minHeight: 52)
        }
    }
}
