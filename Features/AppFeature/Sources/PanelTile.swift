import LoomSharedModels
import SwiftUI

/// One tile in the console's switch strip, and the alert line that covers for it.
///
/// The strip is **glyph + caption**, and the state is carried by the *tint* of
/// both — not by a filled block behind them (DESIGN.md § console). Two reasons
/// the filled version lost: the console draws no lines and no opaque blocks, and
/// three filled rectangles were the heaviest thing on a surface whose job is to
/// be glanced at; and a caption costs one 10pt line and removes the hover-and-
/// wait that a label-less control forces on every reader who isn't its author.
///
/// The caption does **not** free the tile to hold arbitrary state. It says what
/// the control *is*, never what it is doing — the tint says that, in three
/// values. A control whose state needs a phrase (`all but 2 · 3 unread`) belongs
/// in a `PanelRow`, and anything the tint cannot say goes to `ConsoleAlertRow`
/// below.

extension PanelTile.Mode {
    /// `.other` is the reason this mapping is a function rather than a `Bool`.
    /// The system proxy being held by Charles is **not** off: the machine's
    /// traffic is being routed, just not here, and pressing Loom's control again
    /// is not the fix. Rendering it as off is the bug this exists to prevent.
    static func systemProxy(_ routing: SystemProxyRouting) -> Self {
        switch routing {
        case .loom: return .on
        case .other: return .warning
        case .off: return .off
        }
    }

    /// Interception on with an untrusted root CA decrypts **nothing**, so an
    /// `.on` fill there would be a lie the whole capture rests on. The predicate
    /// is `trustState.isReady` — the same one that decides whether the CA-trust
    /// card is showing, because a warning tile whose repair card isn't visible
    /// is a dead end.
    ///
    /// An **empty whitelist** also decrypts nothing (0.0.27) and deliberately does
    /// *not* warn: that is the `rules(enabled:)` case below, not this one. An
    /// untrusted CA defeats something the operator asked for; an empty `include` is
    /// the operator not having asked yet, and orange on the state every fresh install
    /// starts in is how a colour stops being read. The tile's `help` says it instead.
    static func https(sslEnabled: Bool, trust: CertificateTrustState) -> Self {
        guard sslEnabled else { return .off }
        return trust.isReady ? .on : .warning
    }

    /// Rules on with zero rules is deliberately `.on`, not `.warning`: that is
    /// the state of a fresh install, and orange there would teach the reader to
    /// ignore the colour.
    static func rules(enabled: Bool) -> Self { enabled ? .on : .off }
}

/// Whether a phone could reach Loom right now, and the glyph that says so.
///
/// One definition because the control appears on **both** surfaces (the console's
/// tile strip and the main window's status chip), and they used to disagree in
/// the way that matters least and confuses most: the chip *hid* the control while
/// the proxy was stopped. A control that vanishes is a control the reader assumes
/// they imagined — and the stopped case is exactly when someone is hunting for
/// why their phone can't connect. Present and explaining itself beats absent.
enum DeviceReadiness: Equatable {
    /// The proxy isn't listening, so there is nothing for a phone to point at.
    /// Not the same as "LAN capture is off" — this one is fixed by the switch in
    /// the header, not by anything on this control.
    case proxyStopped
    /// The proxy is up but LAN device connection is not allowed.
    case lanDisabled
    case ready

    init(isRunning: Bool, lanEnabled: Bool) {
        guard isRunning else { self = .proxyStopped; return }
        self = lanEnabled ? .ready : .lanDisabled
    }

    /// `iphone.slash` for "can't", and deliberately **not** for "off": a slash is
    /// the word *unavailable*, so using it for a setting the reader turned off
    /// would send them looking for a fault they caused on purpose.
    var symbol: String {
        switch self {
        case .proxyStopped: return "iphone.slash"
        case .lanDisabled: return "iphone"
        case .ready: return "iphone.radiowaves.left.and.right"
        }
    }

    /// Says what is wrong and where the fix is — the control itself cannot start
    /// the proxy, so pointing at it would be a dead end.
    var help: String {
        switch self {
        case .proxyStopped: return "Proxy is stopped — start it to connect a device"
        case .lanDisabled: return "LAN device connection is off"
        case .ready: return "Set up a phone to capture its traffic"
        }
    }

    var isReady: Bool { self == .ready }
}

/// A tap-to-toggle switch drawn as a tinted glyph over its own name.
struct PanelTile: View {
    enum Mode: Equatable {
        case off
        case on
        /// On, but not doing its job — an HTTPS switch with an untrusted CA
        /// decrypts nothing, a System Proxy switch another app has taken routes
        /// nothing here. Orange, and it must be paired with an alert line: a
        /// warning tile is a dead end on its own, because the only thing you can
        /// do to it is the one thing that makes it worse (turn it off).
        case warning
    }

    let icon: String
    let mode: Mode
    /// Drawn as the caption under the glyph, and used for VoiceOver. Keep it to
    /// two short words — it renders at `{typography.caption}` in a third of a
    /// 300pt panel, and a truncated name is worse than the tooltip it replaced.
    let title: String
    /// Trailing-corner count on the glyph. Only for a tile with something
    /// countable — a boolean tile has no number, and inventing one ("1" for on)
    /// would read as a quantity.
    var badge: Int?
    /// `false` for a member that is an **entry point** rather than a switch
    /// (Connect Device). It shares the anatomy because it is the same shape of
    /// thing to a reader — one glyph, one name, a tint that says whether it is
    /// live — but "on/off" is the wrong word for it in VoiceOver, and it must
    /// never grow a `.warning` mode: a fault it can't repair belongs in the alert
    /// channel, and a fault it can belongs in a row.
    var toggles: Bool = true
    /// A change is in flight. Drives a repeating symbol effect — never the only
    /// signal: the `ConsoleAlertRow` underneath carries the spinner and the
    /// sentence. This says *which control* is working, which a strip of four
    /// otherwise cannot, and an unexplained pulsing glyph on its own would be
    /// worse than nothing.
    var busy: Bool = false
    var disabled: Bool = false
    var help: String
    let action: () -> Void

    /// Glyph + caption + the gap between them, pinned so the strip cannot reflow.
    static let contentHeight: CGFloat = 36

    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            VStack(spacing: LoomTheme.Space.xxs) {
                Image(systemName: icon)
                    // Row density, not a display size: the caption underneath is
                    // carrying the meaning now, so the glyph does not have to
                    // shout — and four of them at 18pt made the strip the
                    // heaviest band on a surface meant to be glanced at.
                    .font(LoomTheme.Icon.toolbar)
                    // Two different effects for two different events, and they are
                    // not interchangeable. `.replace` is a TRANSITION — it fires
                    // once, when the glyph itself changes (the helper's key →
                    // key.fill → key.slash), so a state change reads as one symbol
                    // becoming another instead of a silent swap. `.pulse` is a
                    // STATUS — it repeats for as long as a write is in flight.
                    // Both are gated on Reduce Motion; a repeating effect that
                    // ignores it is the kind that makes a menu-bar panel unusable.
                    .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace))
                    .symbolEffect(.pulse, options: .repeating, isActive: busy && !reduceMotion)
                    // Hangs off the glyph's own corner rather than the tile's, so
                    // it reads as belonging to the icon and not to the caption
                    // underneath. Offset out of the layout so it cannot widen the
                    // tile and push the three of them out of equal thirds.
                    .overlay(alignment: .topTrailing) {
                        if let badge, badge > 0 {
                            Text("\(badge)")
                                .font(LoomTheme.Icon.badge)
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 4)
                                .background(.quaternary, in: Capsule())
                                .offset(x: 10, y: -4)
                        }
                    }
                Text(title)
                    .font(.caption)
                    .lineLimit(1)
                    // NO minimumScaleFactor. It was here to protect a two-word
                    // caption in a three-column strip, and it made the captions
                    // *jitter*: expanding a card below re-lays out the whole
                    // panel, the scale factor is recomputed against transient
                    // widths, and the type visibly resizes on a control that
                    // didn't change. Captions are one short word now, so the
                    // protection is unneeded — and a caption that needs it is a
                    // caption that is too long for this strip.
            }
            // Fixed height for the same reason: the strip must be immovable while
            // anything below it opens or closes. Nothing here depends on the
            // panel's height, so nothing here may move with it.
            .frame(height: Self.contentHeight)
            // One tint for glyph AND caption: with no filled block behind them,
            // two tinted things are what carry the state, and tinting only the
            // glyph left "on" reading as a slightly bluer icon.
            .foregroundStyle(tint)
            .frame(maxWidth: .infinity)
            .padding(.vertical, LoomTheme.Space.xxs)
            .background(
                // Hover only — an interaction state, not a display state. The
                // console draws no standing fills; this one exists because a
                // control with no border still has to show its hit target.
                RoundedRectangle(cornerRadius: LoomTheme.Radius.md)
                    .fill(LoomTheme.Palette.accent.opacity(hovering && !disabled ? LoomTheme.attentionOpacity : 0))
            )
            .contentShape(RoundedRectangle(cornerRadius: LoomTheme.Radius.md))
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        // Busy is disabled-for-taps but NOT dimmed: a control that is working is
        // the one thing on the panel the eye should go to, and dimming it to 0.5
        // made the pulsing glyph the faintest thing on screen.
        .opacity(disabled && !busy ? 0.5 : 1)
        .onHover { hovering = $0 }
        .help(help)
        .accessibilityLabel(title)
        .accessibilityValue(accessibilityValue)
        // The caption is abbreviated to fit a third of a 300pt panel; the help
        // text is the unabbreviated sentence, so VoiceOver gets it too rather
        // than only a hovering mouse.
        .accessibilityHint(help)
    }

    private var tint: AnyShapeStyle {
        switch mode {
        case .off: return AnyShapeStyle(.secondary)
        case .on: return AnyShapeStyle(LoomTheme.Palette.accent)
        case .warning: return AnyShapeStyle(LoomTheme.Palette.warning)
        }
    }

    private var accessibilityValue: String {
        switch mode {
        case .off: return toggles ? "off" : "unavailable"
        case .on:
            let state = toggles ? "on" : "ready"
            return badge.map { "\(state), \($0)" } ?? state
        case .warning: return "on, needs attention"
        }
    }
}

/// One line of the console's shared alert channel: what a pure-icon control
/// cannot say, plus the next action rather than only the diagnosis.
///
/// Present **only** while something is wrong, so the ordinary console spends no
/// vertical space on it. Tapping runs the repair — deliberately not the control's
/// own action, which for a warning tile is "turn the broken thing off".
struct ConsoleAlertRow: View {
    let text: String
    /// `nil` when there is nothing Loom can do about it (another app holding the
    /// system proxy is the human's to fix, in that app). Then the row is a
    /// statement, not a button, and shows no chevron.
    var action: (() -> Void)?
    var tint: Color = LoomTheme.Palette.warning
    var busy: Bool = false

    @State private var hovering = false

    var body: some View {
        let content = HStack(alignment: .firstTextBaseline, spacing: LoomTheme.Space.xs) {
            if busy {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(LoomTheme.Icon.badge)
                    .foregroundStyle(tint)
            }
            Text(text)
                .font(.caption)
                .foregroundStyle(tint)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            if action != nil {
                Image(systemName: "chevron.right")
                    .font(LoomTheme.Icon.badge)
                    .foregroundStyle(tint.opacity(0.7))
            }
        }
        .padding(.horizontal, LoomTheme.Space.md)
        .padding(.vertical, LoomTheme.Space.xxs)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())

        Group {
            if let action {
                Button(action: action) { content }
                    .buttonStyle(.plain)
                    .background(
                        RoundedRectangle(cornerRadius: LoomTheme.Radius.sm)
                            .fill(tint.opacity(hovering ? LoomTheme.attentionOpacity : 0))
                            .padding(.horizontal, LoomTheme.Space.xs)
                    )
                    .onHover { hovering = $0 }
            } else {
                content
            }
        }
        .accessibilityLabel(text)
    }
}

/// A bare glyph in the console **header** — no caption, no fill, sized to sit on
/// the same line as the address and the proxy switch.
///
/// This is the third and smallest anatomy, and it exists for exactly the controls
/// that belong beside the address rather than under it: the two ways *out* of the
/// console (main window, device onboarding) and the helper, which is a property
/// of the address's own listener. Its tint is the whole state channel — armed,
/// faulty, or neither — so anything needing more words takes a `ConsoleAlertRow`
/// underneath, which is what the helper does.
///
/// It is **not** a smaller `PanelTile`: it does not toggle, and a control that
/// wants a caption wants the switch strip instead.
struct PanelGlyphButton: View {
    let icon: String
    let title: String
    var tint: Color?
    var badge: Int?
    var busy: Bool = false
    var disabled: Bool = false
    var help: String
    let action: () -> Void

    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                // Header density, not tile density: this shares a line with the
                // address, so it takes the row glyph size rather than the tile's
                // 18pt, which would out-weigh the address itself.
                .font(LoomTheme.Icon.card)
                .foregroundStyle(tint ?? .secondary)
                // The helper is the reason `.replace` earns its place: its glyph
                // is the only one in the console that changes shape with state
                // (key → key.fill → key.slash), and without a transition an
                // install or a failure is a silent swap the eye misses entirely.
                .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace))
                .symbolEffect(.pulse, options: .repeating, isActive: busy && !reduceMotion)
                .overlay(alignment: .topTrailing) {
                    if let badge, badge > 0 {
                        Text("\(badge)")
                            .font(LoomTheme.Icon.badge)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 3)
                            .background(.quaternary, in: Capsule())
                            // Out of layout, so a two-digit count cannot widen the
                            // header and push the address into truncation.
                            .offset(x: 9, y: -6)
                    }
                }
                .frame(width: 18, height: 18)
                .background(
                    RoundedRectangle(cornerRadius: LoomTheme.Radius.sm)
                        .fill(LoomTheme.Palette.accent.opacity(hovering && !disabled ? LoomTheme.attentionOpacity : 0))
                        .padding(-3)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled && !busy ? 0.4 : 1)
        .onHover { hovering = $0 }
        .help(help)
        .accessibilityLabel(title)
        .accessibilityHint(help)
    }
}
