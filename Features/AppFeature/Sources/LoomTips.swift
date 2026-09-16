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

    var title: Text { Text("Nothing is decrypted yet") }

    /// Short on purpose: the console's scarcest resource is height, and a tip that
    /// pushes the config rows off the panel costs more than it explains.
    var message: Text? {
        Text("The scope is a whitelist — every origin is relayed unread until you name one.")
    }

    var image: Image? { Image(systemName: "lock.shield") }

    /// The repair, attached. Same rule as the console's alert channel: a line that
    /// only states a problem is a dead end, because the one thing its own surface
    /// offers is turning the broken thing off.
    /// Built per read rather than held in a static: `Tips.Action` is not `Sendable`,
    /// and this tip has exactly one action, so nothing needs to name it by id.
    var actions: [Tip.Action] {
        [Tip.Action(id: "open-ssl-scope", title: "Open SSL Scope")]
    }

    var rules: [Rule] { #Rule(Self.$interceptsNothing) { $0 } }
}
