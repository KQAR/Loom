import SwiftUI

/// Code mirror of DESIGN.md tokens. Never inline raw values in views — reference
/// these so the design system stays single-sourced.
public enum LoomTheme {
    public enum Space {
        public static let xxs: CGFloat = 4
        public static let xs: CGFloat = 8
        public static let sm: CGFloat = 12
        public static let md: CGFloat = 16
        public static let lg: CGFloat = 20
    }

    public enum Radius {
        public static let sm: CGFloat = 6
        public static let md: CGFloat = 10
        public static let lg: CGFloat = 16
    }

    /// Named icon/badge fonts. Body text uses the semantic system styles
    /// (`.caption`, `.callout`, …); these cover the few glyph/badge spots that
    /// need a fixed point size, so no view inlines `Font.system(size:)`.
    public enum Icon {
        public static let toolbar = Font.system(size: 16, weight: .semibold) // toolbar status glyphs
        public static let card = Font.system(size: 13)                       // cert card / panel-row glyphs
        public static let badge = Font.system(size: 11, weight: .bold)       // count badge
        public static let tiny = Font.system(size: 9)                        // JSON depth guides
    }

    /// Width of the status-bar console popover (DESIGN.md).
    public static let consoleWidth: CGFloat = 300

    /// Fill opacity for an attention/audit tint (e.g. the rule-modified banner),
    /// applied over the single accent — never a second accent hue (DESIGN.md).
    public static let attentionOpacity: CGFloat = 0.12

    /// HTTP status class → semantic color. Color is never the only signal; it always
    /// accompanies the numeric code (see `StatusBadge`).
    public static func statusColor(status: Int?, isError: Bool) -> Color {
        if isError { return .red }
        guard let status else { return .gray } // in flight, no response yet
        switch status {
        case 200 ..< 300: return .green
        case 300 ..< 400: return .orange
        default: return .red
        }
    }
}

/// The one pill/badge style used across the inspector, rules panel and the
/// method/status badges. `tint == nil` gives the neutral quaternary fill;
/// a tint gives colored text on a faint tint of the same hue.
struct CapsuleBadge: View {
    let text: String
    var font: Font = .caption2.weight(.semibold)
    var tint: Color? = nil
    var hPadding: CGFloat = 6
    var vPadding: CGFloat = 2

    var body: some View {
        let label = Text(text)
            .font(font)
            .foregroundStyle(tint ?? Color.secondary)
            .padding(.horizontal, hPadding)
            .padding(.vertical, vPadding)
        if let tint {
            label.background(tint.opacity(0.15), in: Capsule())
        } else {
            label.background(.quaternary, in: Capsule())
        }
    }
}
