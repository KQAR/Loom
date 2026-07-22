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
