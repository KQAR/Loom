import Foundation
import LoomSharedModels

/// Flattened, editable mirror of a `TrafficRule`.
///
/// **Every** field of the model is surfaced by the editor — there are no
/// `carried*` fields any more. That was the shape this type started with, and it
/// failed in the direction that matters: a rule an agent authored with a
/// `mapLocal` route or a `rewriteResponse` opened showing an empty editor, so the
/// human could see the badge on the list row, could not read what it did, could
/// not remove it, and could destroy it by touching an unrelated control (the old
/// `build()` only restored a carried `mapLocal` when nothing else had claimed the
/// route). A field the editor cannot show is a field the human cannot supervise.
struct RuleDraft {
    var id: UUID
    var createdAt: Date
    var isEnabled: Bool
    var name: String
    var comment: String
    var group: String

    /// HTTP methods to match; empty = any. A list, not a single selection: an
    /// agent can scope a rule to `["POST", "PUT"]` and a single-select dropdown
    /// could only ever show — and save — one of them.
    var methods: [String]
    var urlPattern: String
    /// How the pattern is compared. The two chips in the URL row are projections
    /// of this one value (below), so "regex and exact are both on" is not a state
    /// the editor can get into and then have to resolve on save.
    var style: MatchStyle
    var hostPattern: String
    var queryItems: [QueryItem]
    /// Originating app (bundle id or display name) this rule is scoped to; empty = any.
    var sourceApp: String
    /// Originating device IP this rule is scoped to; empty = any.
    var deviceIP: String

    var requestSubs: [SubstitutionRule]
    var responseSubs: [SubstitutionRule]

    /// The request pane's three parts. They were one all-or-nothing toggle over
    /// four fields the model has always kept independent, so "only set a header"
    /// meant opening a form that also offered to replace the method and the body.
    ///
    /// Line and headers carry **no on/off flag**: an empty field is off, which is
    /// what the model already says (`method: String?`, an empty `setHeaders`). A
    /// switch on top of that was a second way to express one fact, and the pair
    /// could disagree — a filled-in method with the switch off looked set and
    /// saved nothing. The body keeps a flag because there an empty value is a
    /// legitimate body (`Keep` vs `Empty`).
    var reqMethod: String
    var reqURL: String

    var reqSetHeaders: String
    var reqRemoveHeaders: String

    var reqBodyOn: Bool
    var reqBodySource: BodySource
    var reqBody: String
    var reqBodyFile: String

    /// The one routing decision, shared by the Replace Response picker and the
    /// Redirect toggle so they cannot both claim it. See `RouteMode`.
    var route: RouteMode

    /// The response pane's three parts, mirroring the request's. Which model
    /// fields they land in depends on `responseSource` — see `build()`.
    var respStatus: String

    var respSetHeaders: String
    var respRemoveHeaders: String

    var respBodyOn: Bool
    var respBodySource: BodySource
    var respBody: String
    var respBodyFile: String
    /// Convenience Content-Type for a synthesized response (`mock`/`mapLocal`
    /// carry one; on the upstream path a Content-Type is just a header, and the
    /// Headers sub-tab is where it goes).
    var respContentType: String
    /// The base64 text, when `respBodySource == .binary`.
    var respBodyBase64: String

    var redirectDest: String
    var redirectExclude: String
    var keepHostHeader: Bool

    /// A response rewrite that coexists with a **synthesized** route.
    ///
    /// The one combination this pane cannot lay out: with the source set to
    /// short-circuit, the three sections write the mock/mapLocal itself, so a
    /// *separate* `rewriteResponse` has nowhere to be edited. It is worth keeping
    /// rather than folding into the mock, because a rewrite applies to whatever
    /// response the matched set produced — including another rule's route — so
    /// merging it here would change behaviour when several rules match. Carried,
    /// and **named on screen** so it is not the invisible kind of carried field.
    private var carriedResponseRewrite: ResponseRewriteAction?

    /// Milliseconds to hold the response back; blank is no delay. No switch, for
    /// the same reason the line and header sections don't have one — an empty
    /// field already says it.
    var delayMs: String
    /// Stop *recording* matching exchanges. In Advanced because it is the one action
    /// that changes nothing about the traffic — the request is forwarded and answered
    /// exactly as it would be without the rule — so it does not belong in the route
    /// segments beside mock/block/redirect, which all do.
    var dropFromCapture: Bool

    init(rule: TrafficRule) {
        id = rule.id
        createdAt = rule.createdAt
        isEnabled = rule.isEnabled
        name = rule.name
        comment = rule.comment ?? ""
        group = rule.group ?? ""
        methods = rule.match.methods
        urlPattern = rule.match.urlPattern
        style = rule.match.style
        hostPattern = rule.match.hostPattern ?? ""
        sourceApp = rule.match.sourceApp ?? ""
        deviceIP = rule.match.deviceIP ?? ""
        // Sort by key so the list has a stable order across edits (query is a dict).
        queryItems = (rule.match.query ?? [:])
            .sorted { $0.key < $1.key }
            .map { QueryItem(key: $0.key, predicate: $0.value) }

        let a = rule.actions
        requestSubs = a.requestSubstitutions
        responseSubs = a.responseSubstitutions

        let reqRewrite = a.rewriteRequest
        reqMethod = reqRewrite?.method ?? ""
        reqURL = reqRewrite?.url ?? ""
        reqSetHeaders = Self.headersToText(reqRewrite?.setHeaders ?? [])
        reqRemoveHeaders = (reqRewrite?.removeHeaders ?? []).joined(separator: ", ")
        reqBodyOn = reqRewrite?.body != nil
        switch reqRewrite?.body {
        case let .text(text):
            reqBodySource = text.isEmpty ? .empty : .text
            reqBody = text
            reqBodyFile = ""
        case let .file(path):
            reqBodySource = .file
            reqBody = ""
            reqBodyFile = path
        case nil:
            reqBodySource = .text
            reqBody = ""
            reqBodyFile = ""
        }

        // Decompose the model's single `route` into the editor's mode + payloads.
        let mock: MockResponseAction? = { if case let .mock(m) = a.route { return m } else { return nil } }()
        let local: MapLocalAction? = { if case let .mapLocal(l) = a.route { return l } else { return nil } }()
        let remote: MapRemoteAction? = { if case let .mapRemote(r) = a.route { return r } else { return nil } }()

        switch a.route {
        case .passthrough: route = .passthrough
        case .block: route = .block
        case .mock: route = .mock
        case .mapLocal: route = .mapLocal
        case .mapRemote: route = .mapRemote
        }

        // The three response sections read from whichever of the three model
        // homes the current route implies: a mock's own status/headers/body, a
        // mapLocal's path/status, or the response rewrite. One pane, three
        // backing shapes — which is why `responseSource` exists to say which.
        let rewriteResp = a.rewriteResponse
        respStatus = mock.map { String($0.statusCode) }
            ?? local.map { String($0.statusCode) }
            ?? rewriteResp?.statusCode.map(String.init) ?? ""

        let respHeaders = mock.map { $0.headers } ?? rewriteResp?.setHeaders ?? []
        let respRemovals = rewriteResp?.removeHeaders ?? []
        respSetHeaders = Self.headersToText(respHeaders)
        respRemoveHeaders = respRemovals.joined(separator: ", ")

        respContentType = mock?.contentType ?? local?.contentType ?? ""
        respBodyBase64 = mock?.bodyBase64 ?? ""
        if let local {
            respBodyOn = true
            respBodySource = .file
            respBody = ""
            respBodyFile = local.path
        } else if let mock {
            respBodyOn = mock.body != nil
            switch mock.body {
            case .bytes: respBodySource = .binary
            case let .text(text): respBodySource = text.isEmpty ? .empty : .text
            case nil: respBodySource = .text
            }
            respBody = mock.bodyText ?? ""
            respBodyFile = ""
        } else {
            respBodyOn = rewriteResp?.bodyText != nil
            respBodySource = (rewriteResp?.bodyText?.isEmpty ?? false) ? .empty : .text
            respBody = rewriteResp?.bodyText ?? ""
            respBodyFile = ""
        }

        redirectDest = remote?.destination ?? ""
        redirectExclude = remote?.excludePattern ?? ""
        keepHostHeader = remote?.keepHostHeader ?? false
        // Whenever the route synthesizes — **block included**. Block hides the three
        // sections entirely (there is nothing to edit about a fixed 403), so a
        // rewrite on a blocking rule has no home in the pane at all; leaving it out
        // of the carry meant saving such a rule silently deleted it.
        carriedResponseRewrite = (mock != nil || local != nil || route == .block) ? rewriteResp : nil

        delayMs = a.delayMilliseconds.map(String.init) ?? ""
        dropFromCapture = a.dropFromCapture
    }

    func build() -> Result<TrafficRule, RuleDraftError> {
        var actions = RuleActions()
        actions.requestSubstitutions = requestSubs.filter { !$0.isEmpty }
        actions.responseSubstitutions = responseSubs.filter { !$0.isEmpty }

        // MARK: request — three independent sections onto one action
        do {
            var rewrite = RequestRewriteAction()
            // Emptiness is the off state — one definition, read here and by the
            // sub-tab dots, so what the bar marks as edited is exactly what saves.
            rewrite.method = reqMethod.trimmingCharacters(in: .whitespaces).isEmpty ? nil : reqMethod
            let url = reqURL.trimmingCharacters(in: .whitespaces)
            rewrite.url = url.isEmpty ? nil : url
            rewrite.setHeaders = Self.textToHeaders(reqSetHeaders)
            rewrite.removeHeaders = Self.textToNames(reqRemoveHeaders)
            if reqBodyOn {
                switch reqBodySource {
                case .empty: rewrite.body = .text("")
                // A request body has no binary kind: `RewriteBody` is text or a
                // file, and the request picker never offers it.
                case .binary, .text: rewrite.body = .text(reqBody)
                case .file:
                    let path = reqBodyFile.trimmingCharacters(in: .whitespaces)
                    guard !path.isEmpty else {
                        return .failure(RuleDraftError(message: "Pick a file for the request body, or switch it to Text."))
                    }
                    rewrite.body = .file(path: path)
                }
            }
            actions.rewriteRequest = rewrite.isEmpty ? nil : rewrite
        }

        // MARK: response — the source decides which model home the sections land in
        let status: Int?
        if !respStatus.trimmingCharacters(in: .whitespaces).isEmpty {
            guard let code = Int(respStatus.trimmingCharacters(in: .whitespaces)) else {
                return .failure(RuleDraftError(message: "Response status must be a number."))
            }
            status = code
        } else {
            status = nil
        }
        let headers = Self.textToHeaders(respSetHeaders)
        let removals = Self.textToNames(respRemoveHeaders)

        switch responseSource {
        case .block:
            actions.route = .block
            actions.rewriteResponse = carriedResponseRewrite
        case .shortCircuit where respBodySource == .file && respBodyOn:
            let path = respBodyFile.trimmingCharacters(in: .whitespaces)
            guard !path.isEmpty else {
                return .failure(RuleDraftError(message: "Pick a file to serve, or switch the body to Text."))
            }
            actions.route = .mapLocal(MapLocalAction(
                path: path,
                statusCode: status ?? 200,
                contentType: respContentType.isEmpty ? nil : respContentType
            ))
            // `MapLocalAction` has no header list of its own, so the headers
            // section rides the response rewrite — which runs *after* the file is
            // served, so it overwrites whatever the extension guessed.
            var rewrite = carriedResponseRewrite ?? ResponseRewriteAction()
            rewrite.setHeaders = headers
            rewrite.removeHeaders = removals
            actions.rewriteResponse = rewrite.isEmpty ? nil : rewrite
        case .shortCircuit:
            var body: MockBody?
            if respBodyOn {
                switch respBodySource {
                case .empty:
                    body = .text("")
                case .file:
                    break // handled by the case above
                case .binary:
                    let trimmed = respBodyBase64.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        guard let data = Data(base64Encoded: trimmed) else {
                            return .failure(RuleDraftError(message: "Mock body is not valid base64."))
                        }
                        body = .bytes(data)
                    }
                case .text:
                    body = .text(respBody)
                }
            }
            actions.route = .mock(MockResponseAction(
                statusCode: status ?? 200,
                headers: headers,
                body: body,
                contentType: respContentType.isEmpty ? nil : respContentType
            ))
            actions.rewriteResponse = carriedResponseRewrite
        case .upstream:
            // Redirect keeps the route when it owns it; everything else falls back
            // to passthrough, and the edits become a response rewrite.
            actions.route = route == .mapRemote
                ? .mapRemote(MapRemoteAction(
                    destination: redirectDest,
                    excludePattern: redirectExclude.isEmpty ? nil : redirectExclude,
                    keepHostHeader: keepHostHeader
                ))
                : .passthrough
            var rewrite = ResponseRewriteAction(statusCode: status, setHeaders: headers, removeHeaders: removals)
            if respBodyOn {
                switch respBodySource {
                case .empty: rewrite.bodyText = ""
                case .text: rewrite.bodyText = respBody
                case .binary, .file:
                    return .failure(RuleDraftError(
                        message: "A binary or file body means the upstream is not called — set the response source to Short-circuit."))
                }
            }
            actions.rewriteResponse = rewrite.isEmpty ? nil : rewrite
        }

        let trimmedDelay = delayMs.trimmingCharacters(in: .whitespaces)
        if !trimmedDelay.isEmpty {
            guard let ms = Int(trimmedDelay) else {
                return .failure(RuleDraftError(message: "Delay must be a number of milliseconds."))
            }
            actions.delayMilliseconds = ms
        }
        actions.dropFromCapture = dropFromCapture

        let trimmedGroup = group.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedComment = comment.trimmingCharacters(in: .whitespacesAndNewlines)
        // Collapse the query rows into the model's dict (blank keys dropped; last
        // wins on a dup key). Order doesn't matter — the matcher is set-based.
        var queryDict: [String: QueryPredicate] = [:]
        for item in queryItems {
            let key = item.key.trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { continue }
            queryDict[key] = item.predicate
        }
        let trimmedHost = hostPattern.trimmingCharacters(in: .whitespaces)
        let trimmedApp = sourceApp.trimmingCharacters(in: .whitespaces)
        let trimmedDevice = deviceIP.trimmingCharacters(in: .whitespaces)
        let rule = TrafficRule(
            id: id,
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            comment: trimmedComment.isEmpty ? nil : trimmedComment,
            group: trimmedGroup.isEmpty ? nil : trimmedGroup,
            isEnabled: isEnabled,
            match: RuleMatch(
                urlPattern: urlPattern,
                // Glob vs prefix follows the pattern the human just typed — the
                // authoring inference, applied once, here. Exact and regex are
                // explicit choices and are left alone.
                style: style == .regex || style == .exact ? style : .inferred(for: urlPattern),
                methods: methods.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty },
                hostPattern: trimmedHost.isEmpty ? nil : trimmedHost,
                query: queryDict.isEmpty ? nil : queryDict,
                sourceApp: trimmedApp.isEmpty ? nil : trimmedApp,
                deviceIP: trimmedDevice.isEmpty ? nil : trimmedDevice
            ),
            actions: actions,
            createdAt: createdAt
        )
        if let reason = rule.validationError() { return .failure(RuleDraftError(message: reason)) }
        return .success(rule)
    }

    /// The URL row's two chips. Each is a projection of `style`: turning one on
    /// selects that style, turning it off falls back to what the pattern itself
    /// says. Mutually exclusive by construction — one value can only hold one.
    var isRegex: Bool {
        get { style == .regex }
        set { style = newValue ? .regex : .inferred(for: urlPattern) }
    }

    var isExact: Bool {
        get { style == .exact }
        set { style = newValue ? .exact : .inferred(for: urlPattern) }
    }

    // MARK: Route <-> segment bindings
    //
    // Both segments write `route`, so picking a route in one turns the other's
    // control off *visibly* (its dot on the segment bar clears) instead of leaving
    // it lit over a value `build()` would have discarded.

    /// Where the response comes from — a projection of `route`, because that is
    /// the property Redirect also writes. Reading it: a redirect still contacts an
    /// upstream (a different one), so its response edits are rewrites like any
    /// other; only mock/mapLocal/block synthesize.
    var responseSource: ResponseSource {
        get {
            switch route {
            case .block: return .block
            case .mock, .mapLocal: return .shortCircuit
            case .passthrough, .mapRemote: return .upstream
            }
        }
        set {
            switch newValue {
            case .block:
                route = .block
            case .shortCircuit:
                route = respBodyOn && respBodySource == .file ? .mapLocal : .mock
            case .upstream:
                // Leave a redirect alone: it is an upstream source, and the
                // Redirect segment owns it.
                if route != .mapRemote { route = .passthrough }
            }
        }
    }

    /// Picking a **file** body means the upstream is not called, so it flips the
    /// source rather than being silently ignored — the same visible-switch rule
    /// the route already follows between Replace Response and Redirect.
    mutating func setResponseBodySource(_ source: BodySource) {
        respBodySource = source
        respBodyOn = true
        // A file is the one body the model expresses as a route of its own.
        if source == .file {
            route = .mapLocal
        } else if route == .mapLocal {
            route = .mock
        }
        // Binary has nowhere to live on the upstream path (a response rewrite's
        // body is a String), so picking it says "synthesize" the same way a file
        // does.
        if source == .binary, route != .mock { route = .mock }
    }

    var redirectOn: Bool {
        get { route == .mapRemote }
        set {
            if newValue { route = .mapRemote }
            else if route == .mapRemote { route = .passthrough }
        }
    }

    /// Whether the rule holds anything the Advanced section owns — the summary
    /// badge on its collapsed header, so a delay set by an agent isn't hidden
    /// behind a closed disclosure with nothing to say it is there.
    var advancedSummary: String {
        var parts: [String] = []
        let trimmed = delayMs.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty { parts.append("delay \(trimmed)ms") }
        if dropFromCapture { parts.append("not captured") }
        return parts.joined(separator: " · ")
    }

    /// Which parts of each message the rule actually edits — the dots on the two
    /// sub-tab bars, and the same predicate `build()` applies. A part is edited
    /// when it holds something, never because a switch says so.
    var requestLineEdited: Bool {
        !reqMethod.trimmingCharacters(in: .whitespaces).isEmpty
            || !reqURL.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var requestHeadersEdited: Bool {
        !Self.textToHeaders(reqSetHeaders).isEmpty || !Self.textToNames(reqRemoveHeaders).isEmpty
    }

    var responseLineEdited: Bool { !respStatus.trimmingCharacters(in: .whitespaces).isEmpty }

    var responseHeadersEdited: Bool {
        !Self.textToHeaders(respSetHeaders).isEmpty || !Self.textToNames(respRemoveHeaders).isEmpty
    }

    /// A response rewrite the current layout is carrying rather than editing —
    /// the view names it so the human knows the rule does more than the pane shows.
    var carriedResponseRewriteSummary: String? {
        guard responseSource != .upstream, let rewrite = carriedResponseRewrite, !rewrite.isEmpty else { return nil }
        var parts: [String] = []
        if rewrite.statusCode != nil { parts.append("status") }
        if !rewrite.setHeaders.isEmpty || !rewrite.removeHeaders.isEmpty { parts.append("headers") }
        if rewrite.bodyText != nil { parts.append("body") }
        return parts.isEmpty ? nil : parts.joined(separator: " + ")
    }

    /// True when a route other than redirect is claimed — the Redirect segment says
    /// so rather than offering a toggle that would silently override it.
    var routeClaimedElsewhere: Bool { route.isClaimed && route != .mapRemote }

    private static func headersToText(_ headers: [HeaderPair]) -> String {
        headers.map { "\($0.name): \($0.value)" }.joined(separator: "\n")
    }

    private static func textToHeaders(_ text: String) -> [HeaderPair] {
        text.split(whereSeparator: \.isNewline).compactMap { line in
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else { return nil }
            let name = parts[0].trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { return nil }
            return HeaderPair(name: name, value: parts[1].trimmingCharacters(in: .whitespaces))
        }
    }

    private static func textToNames(_ text: String) -> [String] {
        text.split(whereSeparator: { $0 == "," || $0.isNewline })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}

/// A human-readable validation failure from rebuilding a draft.
struct RuleDraftError: Error { let message: String }
