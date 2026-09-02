import Foundation

/// Which sidebar group a host belongs to, and whether a host sits under a group.
///
/// The Hosts section is a tree: `api.example.com`, `cdn.example.com` and
/// `example.com` fold under one `example.com` row, the way Charles folds a
/// capture by origin. The parent is the **registrable domain** — the part a
/// human means when they say "the example.com traffic" — and this is the one place
/// that decides what that is, because the grouping (`refreshSidebarRows`) and the
/// filter a parent row applies (`FlowCategory.domain`) must agree byte for byte or
/// clicking a group shows rows its children do not.
///
/// **No public-suffix list.** The real one is ~10 000 rules and moves monthly, and
/// a debugging proxy that ships it is a debugging proxy that is wrong about
/// yesterday's TLDs. What is here instead is the shape that covers what a capture
/// actually contains: the last two labels, or the last three under the handful of
/// two-letter country codes whose second level is a generic (`co.uk`, `com.au`,
/// `com.br`, `co.jp`, …). A host this gets "wrong" (`github.io`, say, grouping every
/// user site together) is still a *coherent* group — every child shares the suffix
/// the row names — which is the property that matters here, since the row is a
/// filter and not a claim about ownership.
enum HostGrouping {
    /// The group a host sorts under. A host that *is* its own registrable domain, an
    /// IP literal, `localhost` or any single label answers itself — those rows have
    /// no parent and are drawn flat.
    static func domain(of host: String) -> String {
        // An IPv6 literal or anything with a port-like suffix never groups.
        if host.contains(":") { return host }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count > 2 else { return host }
        // Four dotted numbers is an address, not a name; slicing its "TLD" would
        // group every 10.0.x.y under `x.y`, which is nonsense.
        if labels.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }) { return host }
        let tld = labels[labels.count - 1]
        let second = labels[labels.count - 2]
        let keep = (tld.count == 2 && genericSecondLevels.contains(second.lowercased())) ? 3 : 2
        guard labels.count > keep else { return host }
        return labels.suffix(keep).joined(separator: ".")
    }

    /// Whether `host` is `domain` itself or a subdomain of it — the filter a group
    /// row applies. Suffix on a label boundary, so `notexample.com` is not under
    /// `example.com`.
    static func isWithin(_ host: String, domain: String) -> Bool {
        guard host.count >= domain.count else { return false }
        if host.count == domain.count { return host == domain }
        return host.hasSuffix(domain) && host[host.index(host.endIndex, offsetBy: -(domain.count + 1))] == "."
    }

    /// Second-level labels that are themselves generic under a two-letter TLD, so the
    /// registrable domain is one label further left. The common ccTLD conventions,
    /// not an exhaustive list — see the type note for why.
    private static let genericSecondLevels: Set<String> = [
        "co", "com", "net", "org", "gov", "edu", "ac", "or", "ne", "go", "mil", "info", "biz",
    ]
}
