import Foundation
import LoomSharedModels

/// What the filter bar's needle is matched against.
///
/// Three scopes rather than one "search everything" box, for the reason
/// `FlowQuery.bodySide` documents: a list endpoint's response body contains every
/// id in the system, so a needle matched against everything answers the question
/// with a page of noise around the one hit. Naming the scope is also what makes the
/// cost legible — `url` is a scan of what the window already holds, the other two
/// are a question for the engine.
public enum FlowSearchScope: String, CaseIterable, Equatable, Sendable {
    case url
    case headers
    case body

    public var label: String {
        switch self {
        case .url: "URL"
        case .headers: "Headers"
        case .body: "Body"
        }
    }

    /// Whether answering this scope needs the engine.
    ///
    /// The window keeps flows **stripped of bodies** (`State.upsertFlow`) and only
    /// hydrates the selected one, so `body` cannot be answered here at all. `headers`
    /// could be — the pairs are in memory — but it goes to the engine with `body` so
    /// there is one rule about freshness rather than two (see `FlowSearch.staleCount`).
    public var needsEngine: Bool { self != .url }
}

/// The main window's filter bar: a needle, a scope, and — for the engine scopes —
/// the answer that came back.
///
/// ## Why this is not the sidebar
///
/// The sidebar answers *whose* traffic (host / app / device / errors): a closed set,
/// single selection, maintained incrementally in `FlowAggregates`. Search answers
/// *which exchange*: an open-ended string. They compose as AND — the category narrows
/// the population, the needle narrows within it — which is why `displayFlows` applies
/// them in that order and why searching deliberately leaves the sidebar badges alone.
/// A badge that moved with the needle could no longer answer the one question worth
/// asking when a search comes back empty: is the filter too narrow, or is the traffic
/// not there?
public struct FlowSearch: Equatable, Sendable {
    /// Whether the bar is on screen. Hidden by default and toggled with ⌘F, the way
    /// a find bar works everywhere else on this platform — the table is the working
    /// surface and a permanently reserved filter row would tax every session for the
    /// few that search.
    ///
    /// Dismissing **clears the needle** rather than keeping it parked off screen. A
    /// hidden filter still applied is a table showing a subset with its cause not
    /// visible anywhere — the same shape as the `isRecording` bug, where a surface
    /// disagreed with the state driving it and nothing on screen could explain why.
    public var isPresented = false
    public var text: String = ""
    public var scope: FlowSearchScope = .url

    /// Ids the engine matched, for an engine scope. `nil` means "no answer yet" and
    /// is deliberately distinct from an empty set, which means "asked, nothing
    /// matched" — the same distinction `TunneledHostLog` exists to preserve, and the
    /// difference between showing a spinner and showing "no matches".
    var engineMatches: Set<Flow.ID>?
    /// A query is in flight.
    var isSearching = false
    /// Matches the engine found that this window cannot show.
    ///
    /// The engine searches everything retained — memory *and* the durable store, an
    /// order of magnitude more — while the table holds the newest `FlowLimits.windowRows`
    /// of them (the store's cap is the same today, but an in-flight capture is not yet
    /// stored, and an embedder can set either). So a headers
    /// or body search can legitimately match an exchange there is no row for, and
    /// showing "3" next to a list of 1 would be a lie by arithmetic. Stated instead.
    var outOfWindowMatches = 0
    /// Flows that arrived after the engine answered. Engine-scope results are a
    /// snapshot on purpose — a body search hydrates payloads off disk, so re-running
    /// it on every 100 ms capture batch would put a disk read per flow on the live
    /// path — so the count is surfaced with a re-run affordance instead of quietly
    /// leaving the list wrong.
    var staleCount = 0

    public init() {}

    /// The trimmed needle, or nil when the bar is effectively empty. Whitespace-only
    /// input is not a search: it would filter everything out and read as "no traffic".
    public var needle: String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Whether anything is being filtered. False while the bar is hidden, which is
    /// what makes "dismiss clears" enforceable in one place rather than at every
    /// call site that could leave a needle behind.
    public var isActive: Bool { isPresented && needle != nil }

    /// Back to the state a fresh window has.
    mutating func dismiss() {
        isPresented = false
        text = ""
        engineMatches = nil
        isSearching = false
        staleCount = 0
        outOfWindowMatches = 0
    }

    /// Does this flow match, given what this surface can see?
    ///
    /// `url` is answered here. The engine scopes are answered by id against the last
    /// result — and while none has landed yet, nothing matches, so the list doesn't
    /// flash the unfiltered capture between keystroke and answer.
    ///
    /// **Per-row entry point — for one flow, not for a scan.** Filtering the window
    /// goes through `predicate()`, which does the trimming and the needle preparation
    /// once instead of once per row. See that comment for what it cost.
    func matches(_ flow: Flow) -> Bool { predicate()(flow) }

    /// The row predicate with everything that doesn't depend on the row hoisted out.
    ///
    /// Built once per projection rebuild. The naive version — `matches(_:)` closing
    /// over `self` — recomputed `needle` **twice per row** (each one a
    /// `trimmingCharacters` allocation) and matched with
    /// `range(of:options:.caseInsensitive)`, which bridges to NSString and walks
    /// grapheme clusters. Measured over a full 20 000-row window: **84 ms per
    /// keystroke**, and the projection is refreshed more than once per keystroke, so
    /// typing into the find bar dropped frames for as long as the field had focus.
    /// Hoisting the trim alone only got it to 69 ms — the search itself was the cost.
    /// Same list through `NeedleMatcher`: **0.76 ms**.
    func predicate() -> (Flow) -> Bool {
        guard isActive, let needle else { return { _ in true } }
        switch scope {
        case .url:
            let matcher = NeedleMatcher(needle)
            return { matcher.contains($0.request.url) }
        case .headers, .body:
            let ids = engineMatches
            return { ids?.contains($0.id) ?? false }
        }
    }

    /// The query to ask the engine, scoped by the sidebar category so the scan is
    /// already narrow before any body is hydrated. Nil when this scope needs no engine.
    ///
    /// The category is folded in here rather than applied afterwards for a reason
    /// specific to `body`: `FlowStore` only hydrates a flow that has passed every
    /// cheap predicate, so a host-scoped search reads a handful of payloads off disk
    /// instead of the whole ring.
    func engineQuery(category: FlowCategory?) -> FlowQuery? {
        guard isActive, let needle, scope.needsEngine else { return nil }
        var query = FlowQuery()
        switch scope {
        case .url: return nil
        case .headers: query.headerContains = needle
        case .body: query.bodyContains = needle
        }
        switch category ?? .all {
        case .all, .rules, .audit, .breakpoints: break
        case .errors: query.onlyErrors = true
        case let .host(host): query.host = host
        case let .app(key): query.sourceApp = key
        case let .device(ip): query.deviceIP = ip
        }
        return query
    }

    /// Whether two search states would produce different rows.
    ///
    /// The projection is refreshed from a `didSet` on the whole struct, so every field
    /// used to trigger a full rescan of the window — including `isSearching`,
    /// `staleCount` and `outOfWindowMatches`, none of which any row is filtered by.
    /// A single keystroke writes two of them, so the scan ran twice for one answer.
    func affectsProjection(comparedTo old: FlowSearch) -> Bool {
        isPresented != old.isPresented
            || scope != old.scope
            || needle != old.needle
            || engineMatches != old.engineMatches
    }
}
