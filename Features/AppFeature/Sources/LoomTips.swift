import SwiftUI
import TipKit

/// Loom's TipKit surface.
///
/// A tip is for the fact that is only wrong to not know **once** — it shows under
/// a rule, is dismissed forever, and is not a state readout. That last part is the
/// boundary against the console's alert channel and the empty state's prose: those
/// two say what is true *now* and carry the repair, so nothing may exist only as a
/// tip. A tip that gets dismissed must leave the surface still answerable.
public enum LoomTips {
    /// Call once at launch, before any `TipView` renders. Failing to open the
    /// datastore means no tips — which is fail-open in the harmless direction, so
    /// unlike the engine's fail-opens this one gets a log line and nothing more.
    public static func configure() {
        do {
            try Tips.configure([.displayFrequency(.immediate)])
        } catch {
            NSLog("TipKit unavailable: \(error.localizedDescription)")
        }
    }
}

/// HTTPS interception is on and the scope is still empty, so Loom is relaying
/// every origin untouched — and an unread relay records **no flow at all**, which
/// is byte-for-byte what "the client never ran" looks like. The whitelist's whole
/// cost is concentrated in this one state (AGENTS.md § "The scope is a whitelist"),
/// and it is a one-time fact rather than a condition to monitor, which is exactly
/// what a tip is for.
struct SSLScopeWhitelistTip: Tip {
    @Parameter static var interceptsNothing: Bool = false

    var title: Text { Text("Name a host to decrypt it") }

    var message: Text? {
        Text(
            "HTTPS interception is on, but the scope is a whitelist — Loom passes every "
                + "origin through unread until you add one. Open SSL Scope in the menu-bar "
                + "console, or ask an agent to intercept a host."
        )
    }

    var image: Image? { Image(systemName: "lock.shield") }

    var rules: [Rule] { #Rule(Self.$interceptsNothing) { $0 } }
}
