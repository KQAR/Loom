import AppKit
import SwiftUI

/// Code mirror of DESIGN.md tokens. Never inline raw values in views — reference
/// these so the design system stays single-sourced.
public enum LoomTheme {
    /// Loom's palette. **The values are not here** — they are color sets in
    /// `Features/AppFeature/Resources/Assets.xcassets`, and this enum is only the
    /// named way in. DESIGN.md § Colors Rule #1 (never write a hex literal in
    /// SwiftUI) therefore still holds literally: no file in the app spells a
    /// component out.
    ///
    /// Why a palette at all, when the system already ships semantic colors: the
    /// stock ones are full-saturation and tuned for *any* app, so a surface using
    /// several at once reads as un-designed — and Loom uses several at once by
    /// construction (a status class, an on/off tint and a fault tint can all be on
    /// screen in one row). These are one family: matched lightness, saturation
    /// pulled back, so they sit beside each other and on the console's vibrant
    /// material without one shouting over the rest.
    ///
    /// Why a catalog rather than a `dynamicProvider` closure, which is what this
    /// started as and is a third the code:
    ///
    /// - **Increase Contrast is a data edit, not a branch.** Each set carries a
    ///   `high` contrast variant per appearance, so the accessibility setting is
    ///   honored by AppKit's own resolution. In code it would mean reading
    ///   `accessibilityDisplayShouldIncreaseContrast` and re-deriving every hue.
    /// - **Wide gamut stays open.** A set can add a Display P3 entry; an
    ///   `NSColor(srgbRed:…)` is sRGB forever.
    /// - **The lookup is checked.** Generated asset symbols mean `Color(.loomError)`
    ///   is a compile-time name, so renaming or deleting a set breaks the build.
    ///   `Color("LoomError")` would resolve to nothing at runtime — the same silent
    ///   failure the custom SF Symbol cost this project once (CLAUDE.md § Known
    ///   Issues), and the reason no string form appears here.
    ///
    /// Resolution is per *view* appearance, not a global read, so a color is right
    /// inside a popover rendering in a different appearance than the window behind.
    ///
    /// The cost, stated because it is a real trade: `accent` no longer follows the
    /// user's system accent. Deliberate — the accent is also the "an agent touched
    /// this" marker, and a marker whose hue the user can set to red or orange
    /// collides with the status voices, which are the one thing here that must
    /// never be ambiguous.
    public enum Palette {
        /// Interactivity, selection, focus, and the "replayed / modified by an
        /// agent" marker. One accent, everywhere (DESIGN.md).
        public static let accent = Color(.loomAccent)
        /// 2xx. Never used for "a switch is on" — that is `accent`; sharing the hue
        /// is what made green stop meaning anything.
        public static let success = Color(.loomSuccess)
        /// 3xx — and `warning` is an alias of it, not a copy: one hue, two names, so
        /// a change to what "a fault the human can fix" looks like cannot silently
        /// restyle every redirect (DESIGN.md § Colors).
        public static let redirect = Color(.loomRedirect)
        /// A fault the human can fix — a warning tile, a not-listening endpoint, a
        /// held breakpoint.
        public static let warning = redirect
        /// "Waiting on you" — softer than `warning`: nothing is broken yet, but
        /// something is parked until a human acts.
        public static let waiting = Color(.loomWaiting)
        /// 4xx / 5xx / transport error, and fault-card fills.
        public static let error = Color(.loomError)
        /// In flight — no response head yet. Stays the *system* grey rather than
        /// getting a set of its own: it is the absence of a status, not a status,
        /// and it should track whatever the system calls disabled.
        public static let pending = Color(nsColor: .systemGray)

        /// Editor syntax highlighting — a deliberate exception to "color is status,
        /// not decoration" (DESIGN.md § inspector). Two of the three reuse status
        /// hues rather than introducing new ones; only the violet is its own, and
        /// only because no status voice is violet, so it cannot be misread as one.
        public enum Syntax {
            public static let string = success
            public static let number = redirect
            public static let bool = Color(.loomSyntaxBool)
            /// The name half of a name/value pair — a header, a cookie, a query
            /// parameter — wherever one is rendered: the Raw panes' message head
            /// and the Headers / Cookies / Query grids.
            ///
            /// The same violet as `bool`, and shared on purpose rather than by
            /// accident: it is the one hue in this palette that is *not* a status
            /// voice, which is precisely why the syntax channel was allowed to
            /// have it. Both uses are that channel — an editor tinting the
            /// keyword-ish token of a line — so one name would have been a
            /// coincidence to re-derive at every call site and two hues would have
            /// spent a second non-status colour Loom does not have.
            public static let name = bool
        }
    }

    /// Recessed surfaces — the fills that lift a container off whatever is behind it.
    ///
    /// Three, and the count is the point. These were five values invented per site
    /// (`0.25`, `0.3`, `0.4` of `.quaternary`, plus `.background` at `0.4` *and* `0.5`),
    /// two of them differing by five hundredths for no reason anyone could state. A
    /// reader can't tell 0.35 from 0.4, but they can absolutely tell that two boxes
    /// meant to be the same kind of box aren't — and with no token, every new card
    /// picked a sixth number.
    ///
    /// All three are *hierarchical* styles, never a color: they are vibrancy-aware, so
    /// the same token is correct on the console's material and in an opaque sheet.
    public enum Surface {
        /// A section box that groups other controls — the outermost recess. Faintest,
        /// because things sit *on* it and it must not compete with them.
        public static let group = AnyShapeStyle(.quaternary.opacity(0.25))
        /// A console card, or a well nested inside a `group`. The value DESIGN.md
        /// already specified for the four console cards; the nested wells in the rule
        /// editor were the same idea under a different number.
        public static let card = AnyShapeStyle(.quaternary.opacity(0.4))
        /// An editable well — a `TextEditor`/custom field. Uses `.background` rather
        /// than `.quaternary` because it must read as *enterable*, i.e. brighter than
        /// its surroundings rather than dimmer. Always paired with the hairline; use
        /// `View.loomField()` so the pair can't come apart.
        public static let field = AnyShapeStyle(.background.opacity(0.5))
    }

    public enum Space {
        public static let xxs: CGFloat = 4
        public static let xs: CGFloat = 8
        public static let sm: CGFloat = 12
        public static let md: CGFloat = 16
        public static let lg: CGFloat = 20
    }

    /// Control metrics for Loom's own wells (`loomField()` and the editor's
    /// fields), which are `.plain` controls inside a drawn surface and so have no
    /// system metric of their own to inherit.
    ///
    /// The app renders in the pre-26 system design (CLAUDE.md § Known Issues), where
    /// an `NSTextField` is 21pt — right for a dense inspector, too tight for a form
    /// the human types URLs and JSON into. These give a ~30pt row: comfortable to
    /// hit, still shorter than a macOS 26 field, and one value so a field, a menu
    /// and a text area can't drift to three different heights.
    public enum Control {
        /// Vertical padding inside an editable well.
        public static let fieldPaddingV: CGFloat = 7
        /// Horizontal padding inside an editable well.
        public static let fieldPaddingH: CGFloat = Space.xs
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
        if isError { return Palette.error }
        guard let status else { return Palette.pending } // in flight, no response yet
        switch status {
        case 200 ..< 300: return Palette.success
        case 300 ..< 400: return Palette.redirect
        default: return Palette.error
        }
    }

    /// Full-row fill for a request whose exchange failed — 4xx/5xx or a transport
    /// error. An `NSColor` because the only row-sized rectangle in a SwiftUI `Table`
    /// belongs to `NSTableRowView` (see `RequestTable.Coordinator.RowView`).
    ///
    /// Nothing else in the table is ever filled. The wash exists so a failure is
    /// findable while scrolling, and a table where several rows are tinted for several
    /// reasons is one where none of them is a signal — a 3xx in particular does not
    /// qualify, a redirect being the wire working.
    ///
    /// 7 %, deliberately weaker than `attentionOpacity`'s 12 %: a row is not a card,
    /// and it still has to read as selectable with the system's own selection fill
    /// drawn over it.
    public static let rowFillError = NSColor(resource: .loomError).withAlphaComponent(0.07)

    /// Whether a flow's outcome earns `rowFillError`. One predicate, so the table's
    /// AppKit fill and anything else that ever asks cannot disagree about what
    /// "failed" means.
    public static func isFailure(status: Int?, isError: Bool) -> Bool {
        isError || (status ?? 0) >= 400
    }

    /// Duration → ink for the request table's `Time` column.
    ///
    /// "Why is this slow" is the second question a capture proxy answers — the first
    /// being "did it fail" — and that column said nothing about it: 40 ms and 4 s were
    /// the same grey. Three bands, and only the outlier is chromatic:
    ///
    /// - under `slowMS`: `.secondary`, i.e. metadata, which is what a fast request is.
    /// - `slowMS …< verySlowMS`: `.primary`. **Weight, not hue** — it deserves to be
    ///   read, but a second color here would compete with the status class beside it
    ///   for the same glance.
    /// - `verySlowMS` and up: `warning`. A fault the human can act on, which is what
    ///   the hue means everywhere else in the app.
    ///
    /// The thresholds are a judgment call, not a measurement: 1 s is where an API call
    /// stops feeling like one, 3 s is where a human assumes something hung.
    public static func durationStyle(ms: Int?) -> AnyShapeStyle {
        guard let ms else { return AnyShapeStyle(.tertiary) } // no duration yet
        if ms >= verySlowMS { return AnyShapeStyle(Palette.warning) }
        if ms >= slowMS { return AnyShapeStyle(.primary) }
        return AnyShapeStyle(.secondary)
    }

    public static let slowMS = 1000
    public static let verySlowMS = 3000

    /// HTTP method → ink. Every verb has its own hue; **only `CONNECT` stays
    /// `{colors.ink}`** (white in Dark, the default label in Light).
    ///
    /// A CONNECT row is a tunnel, not an exchange — no body, no replay — so it
    /// recedes into the same ink as the rest of the row. Every other method is a
    /// verb the operator scans for, and sharing a hue between POST and PUT (or
    /// leaving GET uncoloured) made two different requests look like one.
    /// Hues are the existing palette, never a new set: GET is a read (`success`),
    /// DELETE is a fault-shaped verb (`error`), and so on. One function so the
    /// table, the Summary row, the Raw pane and `MethodBadge` cannot disagree.
    public static func methodColor(_ method: String) -> Color {
        methodTint(method) ?? .primary
    }

    /// The same map, but `nil` for `CONNECT` — for surfaces where "no tint" is a
    /// different *shape*, not a different hue (`MethodBadge`'s neutral capsule).
    public static func methodTint(_ method: String) -> Color? {
        switch method.uppercased() {
        case "CONNECT": return nil
        case "GET": return Palette.success
        case "POST": return Palette.accent
        case "PUT": return Palette.redirect
        case "PATCH": return Palette.waiting
        case "DELETE": return Palette.error
        case "HEAD": return Palette.Syntax.bool
        case "OPTIONS": return Palette.pending
        case "TRACE": return Color.secondary
        default: return Palette.pending
        }
    }
}

extension View {
    /// An editable well: `Surface.field` plus the hairline that makes it read as a
    /// field rather than as a tinted block. One modifier because the two were written
    /// out together at five sites, and a fill without its stroke is indistinguishable
    /// from a decorative panel.
    func loomField(radius: CGFloat = LoomTheme.Radius.sm) -> some View {
        background(LoomTheme.Surface.field, in: RoundedRectangle(cornerRadius: radius))
            .overlay { RoundedRectangle(cornerRadius: radius).stroke(.quaternary) }
    }

    /// A grouping box (`Surface.group`) or a card / nested well (`Surface.card`).
    func loomSurface(_ style: AnyShapeStyle, radius: CGFloat = LoomTheme.Radius.sm) -> some View {
        background(style, in: RoundedRectangle(cornerRadius: radius))
    }
}

/// A dropdown drawn as its own value plus a chevron — no bezel, no well.
///
/// It went through the system pop-up button (AppKit's own bezel and metrics,
/// visibly foreign beside a `LoomTextField`) and then through the field well,
/// which was consistent but heavy: a menu is not somewhere you type, and giving
/// it the enterable surface said it was. What is left is the value and the
/// affordance — the same restraint the console's `config-row` uses, where a
/// chevron is the whole "there is more behind this" vocabulary — with a hover
/// fill because a control that changes silently is one the eye misses
/// (DESIGN.md § Motion).
///
/// Still a `Menu`, so the popup, keyboard handling and accessibility are AppKit's;
/// only the closed state is Loom's.
struct LoomPicker<Value: Hashable>: View {
    @Binding var selection: Value
    let items: [(value: Value, label: String)]
    /// `nil` hugs the current value; a width pins it, so a row of pickers doesn't
    /// reflow as you change one.
    var width: CGFloat?
    /// Matches whatever text it sits among — `.body` in the rule sheet, `.callout`
    /// in the find bar's single dense line.
    var font: Font = .body

    @State private var hovering = false

    private var currentLabel: String {
        items.first { $0.value == selection }?.label ?? ""
    }

    var body: some View {
        Menu {
            ForEach(items, id: \.value) { item in
                Button {
                    selection = item.value
                } label: {
                    // A checkmark only on the selected one — an empty `systemImage`
                    // renders as a missing-symbol placeholder rather than nothing.
                    if item.value == selection { Label(item.label, systemImage: "checkmark") }
                    else { Text(item.label) }
                }
            }
        } label: {
            HStack(spacing: LoomTheme.Space.xxs) {
                Text(currentLabel).font(font).lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
                // Any slack goes *after* the pair. A width is pinned so the row
                // doesn't reflow as the value changes, not to push the chevron to
                // an edge — a borderless control has no edge to push it to, so the
                // gap just read as two unrelated glyphs.
                if width != nil { Spacer(minLength: 0) }
            }
            .padding(.horizontal, LoomTheme.Space.xxs)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: LoomTheme.Radius.sm)
                    .fill(LoomTheme.Palette.accent.opacity(hovering ? LoomTheme.attentionOpacity : 0))
            )
            .contentShape(Rectangle())
        }
        // **Not `.menuStyle(.borderlessButton)`.** Measured with a probe
        // (screenshot, four combinations): that style re-lays-out a custom label
        // and puts the trailing glyph *before* the text — which is why the chevron
        // kept coming out on the left however the `HStack` was ordered. `.plain`
        // button style with the indicator hidden lays the label out as written.
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize(horizontal: width == nil, vertical: true)
        .frame(width: width)
        .onHover { hovering = $0 }
    }
}

/// A bare SF Symbol button that fills on hover — the design system's "this is
/// clickable" affordance (DESIGN.md § Motion). Used for add and remove.
///
/// Glyph-only, same as the console's cards (`ReverseProxyCard`, and
/// DESIGN.md § Components spells it out there): the section a `plus` sits in
/// already says what is being added, so the word spends width on a fact the
/// position gives — while the tooltip and the accessibility label still say it
/// in words. A bordered `+ Add` button per section also out-weighed the rows it
/// was adding to, which is the other half of why they are gone.
struct GlyphButton: View {
    let systemImage: String
    let help: String
    var tint: Color = LoomTheme.Palette.accent
    /// A disabled glyph stays visible rather than disappearing: a control that
    /// vanishes when it can't act reads as a missing feature.
    var isEnabled: Bool = true
    /// The tap target's box. 24 inside a form, where it sits beside 30pt fields;
    /// `compact` (20, an AppKit small control's height) on a panel header, whose
    /// height is set by a single line of `.callout` text — at 24 the glyph became
    /// the tallest thing in the row and pushed the header down.
    var size: CGFloat = 24
    let action: () -> Void

    static let compact: CGFloat = 20

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(size < 24 ? .callout : .body)
                .foregroundStyle(isEnabled ? AnyShapeStyle(tint) : AnyShapeStyle(.tertiary))
                .frame(width: size, height: size)
                .background(
                    RoundedRectangle(cornerRadius: LoomTheme.Radius.sm)
                        .fill(tint.opacity(hovering && isEnabled ? LoomTheme.attentionOpacity : 0))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .onHover { hovering = $0 }
        .help(help)
        .accessibilityLabel(help)
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
