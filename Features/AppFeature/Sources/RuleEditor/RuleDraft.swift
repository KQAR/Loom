import Foundation
import LoomSharedModels

/// Flattened, editable mirror of a `TrafficRule`. Actions the editor doesn't
/// surface (mapLocal, rewriteResponse — reachable via MCP) are carried through
/// unchanged so editing an agent-authored rule never silently drops them.
struct RuleDraft {
    var id: UUID
    var createdAt: Date
    var isEnabled: Bool
    var name: String
    var group: String

    var method: String
    var urlPattern: String
    var isRegex: Bool
    var isExact: Bool
    var hostPattern: String
    var queryItems: [QueryItem]

    var requestSubs: [SubstitutionRule]
    var responseSubs: [SubstitutionRule]

    var replaceReqOn: Bool
    var reqMethod: String
    var reqSetHeaders: String
    var reqRemoveHeaders: String
    var reqBody: String

    var replaceRespMode: ReplaceRespMode
    var mockStatus: String
    var mockContentType: String
    var mockBody: String
    /// When true the mock body is binary, edited as base64 (`mockBodyBase64`)
    /// rather than UTF-8 text (`mockBody`).
    var mockBodyIsBinary: Bool
    var mockBodyBase64: String

    var redirectOn: Bool
    var redirectDest: String
    var redirectExclude: String
    var keepHostHeader: Bool

    var delayOn: Bool
    var delayMs: String

    // Fields the editor doesn't surface but must preserve so editing an
    // MCP-authored rule never silently drops them.
    private var carriedComment: String?
    private var carriedMethods: [String]
    private var carriedMockHeaders: [HeaderPair]
    private var carriedMapLocal: MapLocalAction?
    private var carriedRewriteResponse: ResponseRewriteAction?

    init(rule: TrafficRule) {
        id = rule.id
        createdAt = rule.createdAt
        isEnabled = rule.isEnabled
        name = rule.name
        group = rule.group ?? ""
        method = rule.match.methods.first ?? "ANY"
        urlPattern = rule.match.urlPattern
        isRegex = rule.match.isRegex
        isExact = rule.match.isExact
        hostPattern = rule.match.hostPattern ?? ""
        // Sort by key so the list has a stable order across edits (query is a dict).
        queryItems = (rule.match.query ?? [:])
            .sorted { $0.key < $1.key }
            .map { QueryItem(key: $0.key, value: $0.value) }

        let a = rule.actions
        requestSubs = a.requestSubstitutions
        responseSubs = a.responseSubstitutions

        replaceReqOn = a.rewriteRequest?.isEmpty == false
        reqMethod = a.rewriteRequest?.method ?? ""
        reqSetHeaders = Self.headersToText(a.rewriteRequest?.setHeaders ?? [])
        reqRemoveHeaders = (a.rewriteRequest?.removeHeaders ?? []).joined(separator: ", ")
        reqBody = a.rewriteRequest?.bodyText ?? ""

        // Decompose the single `route` back into the editor's toggles.
        let mock: MockResponseAction? = { if case let .mock(m) = a.route { return m } else { return nil } }()
        let remote: MapRemoteAction? = { if case let .mapRemote(r) = a.route { return r } else { return nil } }()

        switch a.route {
        case .block: replaceRespMode = .block
        case .mock: replaceRespMode = .mock
        default: replaceRespMode = .none
        }
        mockStatus = mock.map { String($0.statusCode) } ?? "200"
        mockContentType = mock?.contentType ?? "application/json"
        // A base64 body (set via MCP for binary payloads) is edited in binary mode;
        // otherwise the UTF-8 text body.
        mockBodyIsBinary = mock?.bodyBase64 != nil
        mockBodyBase64 = mock?.bodyBase64 ?? ""
        mockBody = mock?.bodyText ?? ""

        redirectOn = remote != nil
        redirectDest = remote?.destination ?? ""
        redirectExclude = remote?.excludePattern ?? ""
        keepHostHeader = remote?.keepHostHeader ?? false

        delayOn = a.delayMilliseconds != nil
        delayMs = a.delayMilliseconds.map(String.init) ?? ""

        carriedComment = rule.comment
        carriedMethods = rule.match.methods
        carriedMockHeaders = mock?.headers ?? []
        carriedMapLocal = { if case let .mapLocal(l) = a.route { return l } else { return nil } }()
        carriedRewriteResponse = a.rewriteResponse
    }

    func build() -> Result<TrafficRule, RuleDraftError> {
        var actions = RuleActions()
        actions.requestSubstitutions = requestSubs.filter { !$0.isEmpty }
        actions.responseSubstitutions = responseSubs.filter { !$0.isEmpty }

        if replaceReqOn {
            actions.rewriteRequest = RequestRewriteAction(
                method: reqMethod.isEmpty ? nil : reqMethod,
                setHeaders: Self.textToHeaders(reqSetHeaders),
                removeHeaders: Self.textToNames(reqRemoveHeaders),
                bodyText: reqBody.isEmpty ? nil : reqBody
            )
        }

        // Collapse the editor's separate response controls into the single `route`.
        // Precedence — block > mock > mapRemote > carried mapLocal — so the model
        // can never hold two conflicting routes at once.
        switch replaceRespMode {
        case .none: break
        case .block: actions.route = .block
        case .mock:
            guard let code = Int(mockStatus) else { return .failure(RuleDraftError(message: "Mock status code must be a number.")) }
            // A binary body is base64; validate it up front rather than let
            // `resolvedBody()` silently decode garbage to an empty response.
            if mockBodyIsBinary, !mockBodyBase64.isEmpty,
               Data(base64Encoded: mockBodyBase64.trimmingCharacters(in: .whitespacesAndNewlines)) == nil {
                return .failure(RuleDraftError(message: "Mock body is not valid base64."))
            }
            actions.route = .mock(MockResponseAction(
                statusCode: code,
                headers: carriedMockHeaders, // preserve MCP-set response headers the UI doesn't edit
                bodyText: mockBodyIsBinary || mockBody.isEmpty ? nil : mockBody,
                bodyBase64: mockBodyIsBinary && !mockBodyBase64.isEmpty
                    ? mockBodyBase64.trimmingCharacters(in: .whitespacesAndNewlines) : nil,
                contentType: mockContentType.isEmpty ? nil : mockContentType
            ))
        }
        if case .passthrough = actions.route, redirectOn {
            actions.route = .mapRemote(MapRemoteAction(
                destination: redirectDest,
                excludePattern: redirectExclude.isEmpty ? nil : redirectExclude,
                keepHostHeader: keepHostHeader
            ))
        }
        // Preserve a carried mapLocal (set via MCP; the editor doesn't surface it)
        // only when nothing else claimed the route.
        if case .passthrough = actions.route, let mapLocal = carriedMapLocal {
            actions.route = .mapLocal(mapLocal)
        }

        if delayOn {
            guard let ms = Int(delayMs) else { return .failure(RuleDraftError(message: "Delay must be a number of milliseconds.")) }
            actions.delayMilliseconds = ms
        }
        actions.rewriteResponse = carriedRewriteResponse // editor doesn't surface it

        let trimmedGroup = group.trimmingCharacters(in: .whitespacesAndNewlines)
        // Single-select method dropdown, but keep a multi-method set from MCP intact
        // when the user hasn't touched it.
        let methods: [String]
        if method == "ANY" {
            methods = []
        } else if carriedMethods.count > 1, carriedMethods.first == method {
            methods = carriedMethods
        } else {
            methods = [method]
        }
        // Collapse the query rows into the model's dict (blank keys dropped; last
        // wins on a dup key). Order doesn't matter — the matcher is set-based.
        var queryDict: [String: String] = [:]
        for item in queryItems {
            let key = item.key.trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { continue }
            queryDict[key] = item.value
        }
        let trimmedHost = hostPattern.trimmingCharacters(in: .whitespaces)
        let rule = TrafficRule(
            id: id,
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            comment: carriedComment, // preserved; the editor no longer shows a comment field
            group: trimmedGroup.isEmpty ? nil : trimmedGroup,
            isEnabled: isEnabled,
            match: RuleMatch(
                urlPattern: urlPattern,
                isRegex: isRegex,
                methods: methods,
                // Regex wins over exact in the matcher; keep the model honest.
                isExact: isRegex ? false : isExact,
                hostPattern: trimmedHost.isEmpty ? nil : trimmedHost,
                query: queryDict.isEmpty ? nil : queryDict
            ),
            actions: actions,
            createdAt: createdAt
        )
        if let reason = rule.validationError() { return .failure(RuleDraftError(message: reason)) }
        return .success(rule)
    }

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
