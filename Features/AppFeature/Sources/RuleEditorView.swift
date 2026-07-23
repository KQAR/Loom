import ComposableArchitecture
import SharedModels
import SwiftUI

/// Modal editor for one `TrafficRule`, styled after Reqable's rewrite editors:
/// a compact identity + match header, then one of five action segments — Modify
/// Request / Replace Request / Modify Response / Replace Response / Redirect —
/// with Delay pulled out as its own row. Segments compose (any number active);
/// the dots on the bar show which are configured.
///
/// Presented by `RulesFeature` via `@Presents`. Field editing stays local SwiftUI
/// `@State` over a `RuleDraft`; Save/Cancel relay back as delegate actions.
struct RuleEditorView: View {
    let store: StoreOf<RuleEditorFeature>

    @State private var draft: RuleDraft
    @State private var segment: ActionSegment
    @State private var error: String?
    /// Match-conditions group starts expanded only when host/query are already set,
    /// so the common URL-only rule stays uncluttered.
    @State private var showMatchConditions: Bool

    private var isNew: Bool { store.isNew }
    private var existingGroups: [String] { store.existingGroups }

    init(store: StoreOf<RuleEditorFeature>) {
        self.store = store
        let initial = RuleDraft(rule: store.rule)
        _draft = State(initialValue: initial)
        _segment = State(initialValue: Self.firstActive(in: initial) ?? .replaceResponse)
        _showMatchConditions = State(initialValue: !initial.hostPattern.isEmpty || !initial.queryItems.isEmpty)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: LoomTheme.Space.sm) {
                    identityRow
                    urlRow
                    actionsCard
                    delayRow
                }
                .padding(LoomTheme.Space.md)
            }
            if let error {
                HStack(spacing: LoomTheme.Space.xs) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(error).font(.callout).foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, LoomTheme.Space.md)
                .padding(.vertical, LoomTheme.Space.sm)
                .background(Color.orange.opacity(0.08))
            }
            Divider()
            footer
        }
        .frame(minWidth: 640, idealWidth: 720, minHeight: 560, idealHeight: 720)
    }

    private var header: some View {
        HStack {
            Text(isNew ? "New Rule" : "Edit Rule").font(.headline)
            Spacer()
        }
        .padding(LoomTheme.Space.md)
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button("Cancel", role: .cancel) { store.send(.delegate(.cancel)) }
                .keyboardShortcut(.cancelAction)
            Button("Save") { save() }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
        }
        .padding(LoomTheme.Space.md)
    }

    private func save() {
        switch draft.build() {
        case let .success(rule): store.send(.delegate(.save(rule, isNew: store.isNew)))
        case let .failure(failure): error = failure.message
        }
    }

    // MARK: Identity (group + name on one line)

    private var identityRow: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Name").font(.caption).foregroundStyle(.secondary)
            HStack(spacing: LoomTheme.Space.sm) {
                groupControl
                TextField("", text: $draft.name, prompt: Text("Untitled"))
                    .textFieldStyle(.roundedBorder)
            }
        }
    }

    /// Editable group combo: type a new group, or pick an existing one from the menu.
    private var groupControl: some View {
        HStack(spacing: 2) {
            TextField("", text: $draft.group, prompt: Text("No group"))
                .textFieldStyle(.roundedBorder)
            Menu {
                Button("No group") { draft.group = "" }
                if !existingGroups.isEmpty {
                    Divider()
                    ForEach(existingGroups, id: \.self) { group in
                        Button(group) { draft.group = group }
                    }
                }
            } label: {
                Image(systemName: "folder")
            }
            .menuStyle(.borderlessButton)
            .frame(width: 22)
            .help("Pick an existing group")
        }
        .frame(width: 200)
    }

    // MARK: URL (method + pattern + regex icon)

    private var urlRow: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text("URL").font(.caption).foregroundStyle(.secondary)
                Spacer()
                if draft.isRegex {
                    Text("Regex enabled").font(.caption).foregroundStyle(.green)
                } else if draft.isExact {
                    Text("Exact match").font(.caption).foregroundStyle(.green)
                } else if draft.urlPattern.contains("*") {
                    Text("Wildcards enabled").font(.caption).foregroundStyle(.green)
                }
            }
            HStack(spacing: LoomTheme.Space.sm) {
                Menu {
                    ForEach(Self.methods, id: \.self) { method in
                        Button(method) { draft.method = method }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(draft.method).font(.callout.monospaced())
                        Image(systemName: "chevron.down").font(.caption2)
                    }
                }
                .menuStyle(.borderlessButton)
                .frame(width: 84)
                .padding(.horizontal, LoomTheme.Space.xs)
                .padding(.vertical, 5)
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: LoomTheme.Radius.sm))

                TextField("", text: $draft.urlPattern, prompt: Text("https://api.example.com/*"))
                    .textFieldStyle(.plain)
                    .font(.callout.monospaced())
                    .padding(.horizontal, LoomTheme.Space.sm)
                    .padding(.vertical, 6)
                    .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: LoomTheme.Radius.sm))
                    .overlay(alignment: .trailing) {
                        HStack(spacing: 2) {
                            // Regex and exact are mutually exclusive; enabling one
                            // clears the other so the model never carries both.
                            Button {
                                draft.isExact.toggle()
                                if draft.isExact { draft.isRegex = false }
                            } label: {
                                Text("=")
                                    .font(.callout.monospaced().weight(.bold))
                                    .foregroundStyle(draft.isExact ? Color.accentColor : Color.secondary)
                                    .padding(.horizontal, 6)
                            }
                            .buttonStyle(.plain)
                            .help(draft.isExact ? "Exact on — the URL must equal this pattern exactly" : "Exact off")
                            Button {
                                draft.isRegex.toggle()
                                if draft.isRegex { draft.isExact = false }
                            } label: {
                                Text(".*")
                                    .font(.callout.monospaced().weight(.bold))
                                    .foregroundStyle(draft.isRegex ? Color.accentColor : Color.secondary)
                                    .padding(.horizontal, 6)
                            }
                            .buttonStyle(.plain)
                            .help(draft.isRegex ? "Regex on — matching the URL as a regular expression" : "Regex off — glob/prefix matching")
                        }
                    }
            }
            matchConditions
        }
    }

    // MARK: Match conditions (host + query predicates)

    @ViewBuilder private var matchConditions: some View {
        DisclosureGroup(isExpanded: $showMatchConditions) {
            VStack(alignment: .leading, spacing: LoomTheme.Space.sm) {
                LabeledField("Host") {
                    TextField("", text: $draft.hostPattern, prompt: Text("*.example.com — optional host glob"))
                        .textFieldStyle(.roundedBorder)
                        .font(.callout.monospaced())
                }
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Query predicates — value * means any value").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button {
                            draft.queryItems.append(QueryItem(key: "", value: ""))
                        } label: { Label("Add", systemImage: "plus") }
                        .controlSize(.small)
                    }
                    ForEach($draft.queryItems) { $item in
                        HStack(spacing: LoomTheme.Space.xs) {
                            TextField("", text: $item.key, prompt: Text("key"))
                                .textFieldStyle(.roundedBorder).font(.callout.monospaced())
                            Text("=").foregroundStyle(.secondary)
                            TextField("", text: $item.value, prompt: Text("value or *"))
                                .textFieldStyle(.roundedBorder).font(.callout.monospaced())
                            Button(role: .destructive) {
                                draft.queryItems.removeAll { $0.id == item.id }
                            } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless).controlSize(.small)
                        }
                    }
                }
            }
            .padding(.top, LoomTheme.Space.xs)
        } label: {
            Text("Match conditions\(matchConditionsSummary)").font(.caption).foregroundStyle(.secondary)
        }
    }

    /// Compact " · host, 2 query" summary so a collapsed group still shows it's set.
    private var matchConditionsSummary: String {
        var parts: [String] = []
        if !draft.hostPattern.trimmingCharacters(in: .whitespaces).isEmpty { parts.append("host") }
        let queries = draft.queryItems.filter { !$0.key.trimmingCharacters(in: .whitespaces).isEmpty }.count
        if queries > 0 { parts.append("\(queries) query") }
        return parts.isEmpty ? "" : " · " + parts.joined(separator: ", ")
    }

    // MARK: Actions — segmented, additive

    private var actionsCard: some View {
        VStack(alignment: .leading, spacing: LoomTheme.Space.sm) {
            SegmentBar(selection: $segment, active: activeSegments)
            VStack(alignment: .leading, spacing: LoomTheme.Space.sm) {
                switch segment {
                case .modifyRequest:
                    SubstitutionListEditor(
                        subs: $draft.requestSubs, allowURL: true,
                        hint: "Find/replace in the request URL, header values, or body — applied in order before forwarding."
                    )
                case .replaceRequest: replaceRequestSection
                case .modifyResponse:
                    SubstitutionListEditor(
                        subs: $draft.responseSubs, allowURL: false,
                        hint: "Find/replace in the response header values or body — applied to whatever response is returned."
                    )
                case .replaceResponse: replaceResponseSection
                case .redirect: redirectSection
                }
            }
            .padding(LoomTheme.Space.sm)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: LoomTheme.Radius.md))
        }
    }

    private var activeSegments: Set<ActionSegment> {
        var active: Set<ActionSegment> = []
        if !draft.requestSubs.filter({ !$0.isEmpty }).isEmpty { active.insert(.modifyRequest) }
        if draft.replaceReqOn { active.insert(.replaceRequest) }
        if !draft.responseSubs.filter({ !$0.isEmpty }).isEmpty { active.insert(.modifyResponse) }
        if draft.replaceRespMode != .none { active.insert(.replaceResponse) }
        if draft.redirectOn { active.insert(.redirect) }
        return active
    }

    private static func firstActive(in draft: RuleDraft) -> ActionSegment? {
        if !draft.requestSubs.filter({ !$0.isEmpty }).isEmpty { return .modifyRequest }
        if draft.replaceReqOn { return .replaceRequest }
        if !draft.responseSubs.filter({ !$0.isEmpty }).isEmpty { return .modifyResponse }
        if draft.replaceRespMode != .none { return .replaceResponse }
        if draft.redirectOn { return .redirect }
        return nil
    }

    @ViewBuilder private var replaceRequestSection: some View {
        Toggle("Replace the outgoing request", isOn: $draft.replaceReqOn)
        if draft.replaceReqOn {
            LabeledField("Method override") {
                TextField("", text: $draft.reqMethod, prompt: Text("leave blank to keep"))
            }
            HeaderEditor(title: "Headers", text: $draft.reqSetHeaders)
            LabeledField("Remove headers") {
                TextField("", text: $draft.reqRemoveHeaders, prompt: Text("comma-separated names"))
            }
            JSONBodyEditor(title: "Body", text: $draft.reqBody)
        } else {
            sectionHint("Set the outgoing request's method / headers / body wholesale before it is forwarded upstream.")
        }
    }

    @ViewBuilder private var replaceResponseSection: some View {
        Picker("", selection: $draft.replaceRespMode) {
            Text("Off").tag(ReplaceRespMode.none)
            Text("Mock").tag(ReplaceRespMode.mock)
            Text("Block (403)").tag(ReplaceRespMode.block)
        }
        .pickerStyle(.segmented)
        .labelsHidden()

        switch draft.replaceRespMode {
        case .none:
            sectionHint("Return a canned response instead of contacting the upstream.")
        case .block:
            sectionHint("Refuse the request with 403; the upstream is never contacted.")
        case .mock:
            HStack(spacing: LoomTheme.Space.md) {
                LabeledField("Status") { TextField("", text: $draft.mockStatus).frame(width: 80) }
                LabeledField("Content-Type") { TextField("", text: $draft.mockContentType) }
            }
            HStack {
                Spacer()
                Toggle("Binary (base64)", isOn: $draft.mockBodyIsBinary)
                    .toggleStyle(.checkbox)
                    .font(.caption)
                    .help("Provide the body as base64 for binary payloads (images, protobuf, gzip) that aren't valid UTF-8 text.")
            }
            if draft.mockBodyIsBinary {
                LabeledField("Body (base64)") {
                    TextEditor(text: $draft.mockBodyBase64)
                        .font(.callout.monospaced())
                        .frame(minHeight: 96)
                        .scrollContentBackground(.hidden)
                        .padding(4)
                        .background(.background.opacity(0.5), in: RoundedRectangle(cornerRadius: LoomTheme.Radius.sm))
                        .overlay(RoundedRectangle(cornerRadius: LoomTheme.Radius.sm).stroke(.quaternary))
                }
            } else {
                JSONBodyEditor(title: "Body", text: $draft.mockBody)
            }
        }
    }

    @ViewBuilder private var redirectSection: some View {
        Toggle("Redirect to another URL", isOn: $draft.redirectOn)
        if draft.redirectOn {
            LabeledField("Redirect to") {
                TextField("", text: $draft.redirectDest, prompt: Text("https://localhost:3000"))
                    .font(.callout.monospaced())
            }
            LabeledField("Exclude URL (optional)") {
                TextField("", text: $draft.redirectExclude, prompt: Text("https://api.example.com/keep/*"))
                    .font(.callout.monospaced())
            }
            Toggle("Keep Host header", isOn: $draft.keepHostHeader)
                .help("The request's Host header stays unchanged instead of following the new origin.")
        } else {
            sectionHint("Send matching requests to a different scheme / host / port, keeping the path + query.")
        }
    }

    private var delayRow: some View {
        HStack(spacing: LoomTheme.Space.md) {
            Toggle("Delay response", isOn: $draft.delayOn)
            if draft.delayOn {
                TextField("", text: $draft.delayMs, prompt: Text("ms")).frame(width: 100)
                Text("ms").foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, LoomTheme.Space.md)
        .padding(.vertical, LoomTheme.Space.sm)
        .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: LoomTheme.Radius.md))
    }

    private func sectionHint(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private static let methods = ["ANY", "GET", "POST", "PUT", "DELETE", "PATCH", "HEAD", "OPTIONS"]
}

// MARK: - Segment bar

private struct SegmentBar: View {
    @Binding var selection: ActionSegment
    let active: Set<ActionSegment>

    var body: some View {
        HStack(spacing: 0) {
            ForEach(ActionSegment.allCases) { seg in
                Button { selection = seg } label: {
                    HStack(spacing: 4) {
                        Text(seg.label)
                        if active.contains(seg) {
                            Circle().fill(Color.accentColor).frame(width: 6, height: 6)
                        }
                    }
                    .font(.caption.weight(selection == seg ? .semibold : .regular))
                    .foregroundStyle(selection == seg ? Color.primary : Color.secondary)
                    .padding(.vertical, LoomTheme.Space.xs)
                    .frame(maxWidth: .infinity)
                    .background(
                        selection == seg ? Color.accentColor.opacity(0.15) : Color.clear,
                        in: RoundedRectangle(cornerRadius: LoomTheme.Radius.sm)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: LoomTheme.Radius.md))
    }
}

enum ActionSegment: String, CaseIterable, Identifiable {
    case modifyRequest, replaceRequest, modifyResponse, replaceResponse, redirect
    var id: String { rawValue }
    var label: String {
        switch self {
        case .modifyRequest: return "Modify Req"
        case .replaceRequest: return "Replace Req"
        case .modifyResponse: return "Modify Resp"
        case .replaceResponse: return "Replace Resp"
        case .redirect: return "Redirect"
        }
    }
}

// MARK: - Substitution list editor (whistle-style find/replace)

private struct SubstitutionListEditor: View {
    @Binding var subs: [SubstitutionRule]
    let allowURL: Bool
    let hint: String

    var body: some View {
        VStack(alignment: .leading, spacing: LoomTheme.Space.sm) {
            HStack {
                Text(hint).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button {
                    subs.append(SubstitutionRule(field: allowURL ? .url : .body, match: "", replacement: ""))
                } label: {
                    Label("Add", systemImage: "plus")
                }
                .controlSize(.small)
            }

            if subs.isEmpty {
                Text("No substitutions yet.").font(.callout).foregroundStyle(.tertiary)
            } else {
                ForEach($subs) { $sub in
                    SubstitutionRow(sub: $sub, allowURL: allowURL) {
                        subs.removeAll { $0.id == sub.id }
                    }
                }
            }
        }
    }
}

private struct SubstitutionRow: View {
    @Binding var sub: SubstitutionRule
    let allowURL: Bool
    let onDelete: () -> Void

    private var fields: [SubstitutionRule.Field] {
        allowURL ? [.url, .header, .body] : [.header, .body]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: LoomTheme.Space.xs) {
                Menu {
                    ForEach(fields, id: \.self) { field in
                        Button(Self.label(field)) { sub.field = field }
                    }
                } label: {
                    HStack(spacing: 3) {
                        Text(Self.label(sub.field)).font(.caption)
                        Image(systemName: "chevron.down").font(.caption2)
                    }
                }
                .menuStyle(.borderlessButton)
                .frame(width: 78)

                iconToggle("Aa", on: sub.caseSensitive, help: "Case-sensitive match") { sub.caseSensitive.toggle() }
                iconToggle(".*", on: sub.isRegex, help: "Regex match") { sub.isRegex.toggle() }

                Spacer()

                Button(role: .destructive, action: onDelete) {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
            }
            TextField("", text: $sub.match, prompt: Text("find (e.g. key=12345)"))
                .textFieldStyle(.roundedBorder)
                .font(.callout.monospaced())
            TextField("", text: $sub.replacement, prompt: Text("replace with (e.g. key=54321)"))
                .textFieldStyle(.roundedBorder)
                .font(.callout.monospaced())
        }
        .padding(LoomTheme.Space.sm)
        .background(.background.opacity(0.4), in: RoundedRectangle(cornerRadius: LoomTheme.Radius.sm))
        .overlay(RoundedRectangle(cornerRadius: LoomTheme.Radius.sm).stroke(.quaternary))
    }

    private func iconToggle(_ text: String, on: Bool, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(text)
                .font(.caption.monospaced().weight(.bold))
                .foregroundStyle(on ? Color.accentColor : Color.secondary)
                .frame(width: 24, height: 20)
                .background(on ? Color.accentColor.opacity(0.15) : Color.clear, in: RoundedRectangle(cornerRadius: 4))
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private static func label(_ field: SubstitutionRule.Field) -> String {
        switch field {
        case .url: return "URL"
        case .header: return "Header"
        case .body: return "Body"
        }
    }
}

// MARK: - Shared building blocks

private struct LabeledField<Content: View>: View {
    let label: String
    @ViewBuilder let content: Content

    init(_ label: String, @ViewBuilder content: () -> Content) {
        self.label = label
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            content
        }
    }
}

private struct HeaderEditor: View {
    let title: String
    @Binding var text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(title) — Name: Value per line").font(.caption).foregroundStyle(.secondary)
            TextEditor(text: $text)
                .font(.callout.monospaced())
                .frame(minHeight: 44)
                .scrollContentBackground(.hidden)
                .padding(4)
                .background(.background.opacity(0.5), in: RoundedRectangle(cornerRadius: LoomTheme.Radius.sm))
                .overlay(RoundedRectangle(cornerRadius: LoomTheme.Radius.sm).stroke(.quaternary))
        }
    }
}

/// Body editor with Edit/Preview toggle and a Format action. Preview renders the
/// collapsible, syntax-highlighted `JSONView`; Format pretty-prints in place while
/// preserving key order.
private struct JSONBodyEditor: View {
    let title: String
    @Binding var text: String
    @State private var showPreview = false

    private var parsed: JSONValue? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return JSONValue.parse(Data(trimmed.utf8))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: LoomTheme.Space.xs) {
                Text(title).font(.caption).foregroundStyle(.secondary)
                Spacer()
                if parsed != nil {
                    Button("Format") { if let json = parsed { text = json.prettyPrinted() } }
                        .buttonStyle(.borderless).controlSize(.small)
                    Picker("", selection: $showPreview) {
                        Text("Edit").tag(false)
                        Text("Preview").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 130)
                } else if !text.isEmpty {
                    Text("not JSON").font(.caption2).foregroundStyle(.tertiary)
                }
            }

            if showPreview, let json = parsed {
                ScrollView {
                    JSONView(value: json)
                        .padding(LoomTheme.Space.sm)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(minHeight: 120, maxHeight: 260)
                .background(.background.opacity(0.5), in: RoundedRectangle(cornerRadius: LoomTheme.Radius.sm))
                .overlay(RoundedRectangle(cornerRadius: LoomTheme.Radius.sm).stroke(.quaternary))
            } else {
                TextEditor(text: $text)
                    .font(.callout.monospaced())
                    .frame(minHeight: 96)
                    .scrollContentBackground(.hidden)
                    .padding(4)
                    .background(.background.opacity(0.5), in: RoundedRectangle(cornerRadius: LoomTheme.Radius.sm))
                    .overlay(RoundedRectangle(cornerRadius: LoomTheme.Radius.sm).stroke(.quaternary))
            }
        }
    }
}

// MARK: - Draft

enum ReplaceRespMode: Hashable { case none, mock, block }

/// One editable query predicate row. `value` of `*` means presence-only (any
/// value), matching `RuleMatch.query` semantics.
struct QueryItem: Identifiable, Equatable {
    let id = UUID()
    var key: String
    var value: String
}

/// A human-readable validation failure from rebuilding a draft.
struct RuleDraftError: Error { let message: String }

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
