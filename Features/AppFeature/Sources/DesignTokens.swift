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
        public static let fab = Font.system(size: 15, weight: .semibold)     // floating action disc (clear capture)
        public static let tiny = Font.system(size: 9)                        // JSON depth guides
    }

    /// Width of the status-bar console popover (DESIGN.md).
    ///
    /// 272, down from 300. The panel is config and control, never traffic, so its
    /// widest content is a row title plus a two-word state — nothing here wants a
    /// wide surface, and a menu-bar popover that reaches a third of the way across
    /// a laptop screen reads as a window that forgot to be a popover. What sets
    /// the floor is the `Client Certificates` row: its title plus its longest
    /// state is the widest line the console can produce, which is why that state
    /// is now two words rather than three.
    public static let consoleWidth: CGFloat = 272

    /// Horizontal margin inside the console — **narrower than the main window's**
    /// (`Space.sm`, not `Space.md`). At 300pt the margin is a percentage of the
    /// surface, not a constant: 16pt each side spends 11 % of the width on
    /// nothing, and it is the width that a row's trailing detail, a four-column
    /// tile strip and a long LAN address are all competing for. Single-sourced so
    /// the bands cannot drift apart — a card that keeps 16 while its row moves to
    /// 12 hangs past the row it belongs to.
    public static let consoleMargin: CGFloat = Space.sm

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
