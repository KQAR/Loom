import Foundation
import LoomSharedModels

/// How a `TrafficRule` is summarised on the rules list row.
///
/// A free function rather than a computed property inside the row view, because
/// the thing that goes wrong here is *omission* — a badge set that silently stops
/// covering an action is indistinguishable from a rule that does nothing — and an
/// omission is only catchable by a test that can call this directly.
enum RuleSummary {
    /// What the rule *does*, one badge per action. Every branch of `RuleActions`
    /// is represented: the substitution lists were missing, which made a
    /// find/replace rule — the shape the editor's two Modify segments produce, so
    /// the one a human is most likely to have authored by hand — render with no
    /// badge at all, exactly like an empty passthrough rule.
    static func actionBadges(for rule: TrafficRule) -> [String] {
        let a = rule.actions
        var badges: [String] = []
        switch a.route {
        case .passthrough: break
        case .block: badges.append("BLOCK")
        case .mock: badges.append("MOCK")
        case .mapRemote: badges.append("MAP REMOTE")
        case .mapLocal: badges.append("MAP LOCAL")
        }
        if a.rewriteRequest?.isEmpty == false { badges.append("REQ") }
        if a.rewriteResponse?.isEmpty == false { badges.append("RES") }
        let requestSubs = a.activeRequestSubstitutions.count
        if requestSubs > 0 { badges.append(requestSubs == 1 ? "SUB REQ" : "SUB REQ ×\(requestSubs)") }
        let responseSubs = a.activeResponseSubstitutions.count
        if responseSubs > 0 { badges.append(responseSubs == 1 ? "SUB RES" : "SUB RES ×\(responseSubs)") }
        if let ms = a.delayMilliseconds { badges.append("DELAY \(ms)ms") }
        return badges
    }

    /// Who the rule is limited to. Origin scope fails closed — an app-scoped rule
    /// never matches traffic Loom couldn't attribute — so "my rule isn't firing"
    /// is most often this, and it was invisible on the row.
    static func scopeBadges(for rule: TrafficRule) -> [ScopeBadge] {
        var badges: [ScopeBadge] = []
        if let app = rule.match.sourceApp, !app.isEmpty {
            badges.append(ScopeBadge(text: "APP", detail: "Only requests from \(app)"))
        }
        if let device = rule.match.deviceIP, !device.isEmpty {
            badges.append(ScopeBadge(text: "DEVICE", detail: "Only requests from \(device)"))
        }
        return badges
    }

    /// The match line under the rule name: methods, the host predicate (which
    /// narrows every rule and had no rendering anywhere), and the URL pattern.
    static func patternText(for rule: TrafficRule) -> String {
        var parts: [String] = []
        if !rule.match.methods.isEmpty {
            parts.append(rule.match.methods.joined(separator: "/").uppercased())
        }
        if let host = rule.match.hostPattern, !host.isEmpty {
            parts.append("host:\(host)")
        }
        parts.append(rule.match.isRegex ? "/\(rule.match.urlPattern)/" : rule.match.urlPattern)
        return parts.joined(separator: " ")
    }

    /// A scope badge plus the tooltip that carries the value — the badge itself
    /// stays short so a long bundle id can't push the rule name off the row.
    struct ScopeBadge: Equatable, Identifiable {
        let text: String
        let detail: String
        var id: String { text }
    }
}
