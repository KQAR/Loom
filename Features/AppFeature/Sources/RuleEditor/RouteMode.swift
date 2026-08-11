/// The editor's mirror of `Route` — the one mutually-exclusive routing decision.
///
/// It is a *single* draft property even though the editor spreads it over two
/// segments (Replace Response's source picker owns mock / mapLocal / block,
/// Redirect owns mapRemote). Two independent flags let the editor show "mock
/// **and** redirect are on" while `build()` silently picked one; sharing this
/// property makes that state unrepresentable, the same way `Route` does in the
/// model.
enum RouteMode: Hashable {
    case passthrough
    case block
    case mock
    case mapLocal
    case mapRemote

    /// True when this route short-circuits or re-targets — i.e. it is claimed by
    /// one segment and the other must show itself as off.
    var isClaimed: Bool { self != .passthrough }
}

/// Where the response comes from — the one fact the Replace Response pane's three
/// sub-sections cannot carry, and the one that decides whether the upstream is
/// contacted at all.
///
/// It exists because "response body = a local file" is ambiguous without it. Under
/// `shortCircuit` the upstream is **never called** (no side effects, no latency,
/// the status and headers are yours); under `upstream` the request really happens
/// and only what comes back is edited. Those are different debugging tools, and
/// collapsing them into one "body source" control would have made the difference
/// unsayable.
enum ResponseSource: Hashable {
    /// Fetch the real response (or the redirected one), then edit it — writes
    /// `RuleActions.rewriteResponse`.
    case upstream
    /// Synthesize the response — writes `Route.mock` (text/empty body) or
    /// `Route.mapLocal` (file body).
    case shortCircuit
    /// Refuse with 403 — writes `Route.block`, which also outranks every other
    /// route across matched rules.
    case block
}

/// Where a replacement body's bytes come from. The three presets the request and
/// response body sections both offer.
enum BodySource: Hashable {
    /// A body of zero bytes — *not* the same as leaving the body alone, which is
    /// the `Keep` entry in the same picker.
    case empty
    case text
    /// Base64, for a payload that isn't valid UTF-8 (an image, protobuf, gzip).
    ///
    /// **A kind of body, not a modifier of `text`.** It was a "Binary (base64)"
    /// checkbox beside the Content-Type field, which made it a second control
    /// deciding the same thing the type picker decides, on a row whose two halves
    /// could never line up. Only a synthesized response can carry one —
    /// `ResponseRewriteAction`'s body is a `String` — so the picker offers it only
    /// when the source short-circuits.
    case binary
    /// Read at request time, so editing the fixture needs no rule change.
    case file
}
