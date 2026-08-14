import AppKit
import ComposableArchitecture
import LoomSharedModels
import SwiftUI

/// Modal editor for one `TrafficRule`, styled after Reqable's rewrite editors:
/// a compact identity + match header, then one of five action segments — Modify
/// Request / Replace Request / Modify Response / Replace Response / Redirect —
/// with Delay pulled out as its own row. Segments compose (any number active);
/// the dots on the bar show which are configured.
///
/// The one thing they do *not* compose is the route: Replace Response's picker
/// and the Redirect toggle both write `RuleDraft.route`, so choosing one clears
/// the other on screen instead of leaving both lit over a value `build()` would
/// have quietly dropped.
///
/// Every control comes from `EditorControls.swift` — one field, one text area,
/// one glyph button, one toggle tint. Nothing here reaches for `.roundedBorder`
/// or a bare default field: three field renderings in one sheet was the state
/// this replaced.
///
/// Presented by `RulesFeature` via `@Presents`. Field editing stays local SwiftUI
/// `@State` over a `RuleDraft`; Save/Cancel relay back as delegate actions.
struct RuleEditorView: View {
    let store: StoreOf<RuleEditorFeature>

    @State private var draft: RuleDraft
    @State private var segment: ActionSegment
    @State private var error: String?
    /// Match-conditions group starts expanded only when host/query/app/device are
    /// already set, so the common URL-only rule stays uncluttered — and a rule an
    /// agent scoped to one app opens showing that scope rather than hiding it.
    @State private var showMatchConditions: Bool
    /// Which part of each message the two Replace panes are showing. View state,
    /// not draft state: it says what you are looking at, never what gets saved.
    @State private var requestPart: MessagePart = .line
    @State private var responsePart: MessagePart = .body
    /// Collapsed unless the rule already carries something advanced — the same
    /// rule Match conditions follows, so a closed disclosure never hides a setting
    /// that is actually in force.
    @State private var showAdvanced: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isNew: Bool { store.isNew }
    private var existingGroups: [String] { store.existingGroups }

    init(store: StoreOf<RuleEditorFeature>) {
        self.store = store
        let initial = RuleDraft(rule: store.rule)
        _draft = State(initialValue: initial)
        _segment = State(initialValue: Self.firstActive(in: initial) ?? .replaceResponse)
        _showMatchConditions = State(
            initialValue: !initial.hostPattern.isEmpty || !initial.queryItems.isEmpty
                || !initial.sourceApp.isEmpty || !initial.deviceIP.isEmpty
        )
        _showAdvanced = State(initialValue: !initial.advancedSummary.isEmpty)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: LoomTheme.Space.md) {
                    identityRow
                    urlRow
                    actionsCard
                    advancedSection
                }
                .padding(LoomTheme.Space.md)
            }
            errorBar
        }
        .frame(minWidth: 640, idealWidth: 720, minHeight: 560, idealHeight: 720)
        .task { await clearInitialFocus() }
        // Typing into any field clears a stale validation message: it names a
        // problem the human is in the middle of fixing.
        .onChange(of: draft.name) { error = nil }
        .onChange(of: draft.urlPattern) { error = nil }
    }

    /// Opens with nothing focused.
    ///
    /// A sheet's first responder goes to its first text field, which here is the
    /// rule's **Name** — already filled in on an existing rule, and selected, so
    /// the first keystroke replaced it. A destructive default on a surface whose
    /// whole job is editing something that already exists.
    ///
    /// **There is no Loom code to delete instead.** Measured with a standalone
    /// SwiftUI probe (a bare sheet holding two `.plain` `TextField`s and nothing
    /// else): the sheet's field editor comes up holding the first field's text
    /// with nothing asking for it. It is AppKit's `initialFirstResponder`, not a
    /// focus request of ours — `@FocusState` + `.focused()` only *observes*.
    ///
    /// The same probe fixed the shape of the fix: **one** hop is enough and it
    /// sticks (still clear at 400 ms and 1 s), so this is not a race papered over
    /// with a delay — and a single `Task.yield()` on the main actor is that hop,
    /// no `DispatchQueue` needed. AppKit rather than `.defaultFocus` because each
    /// field owns its own `@FocusState` — that is what draws the accent ring — so
    /// SwiftUI's version has no single binding to point at. Scoped to visible
    /// sheets so it can never resign the main window's own first responder, which
    /// would silently break the table's keyboard navigation.
    @MainActor
    private func clearInitialFocus() async {
        await Task.yield()
        for window in NSApp.windows where window.isSheet && window.isVisible {
            window.makeFirstResponder(nil)
        }
    }

    /// Title bar: enabled-checkbox · title · Cancel / Save.
    ///
    /// The checkbox is the same control the rules list row uses for the same fact,
    /// in the same place (leading, before the name) — a switch on the far right
    /// was a second vocabulary for one bit. Cancel/Save live here rather than in a
    /// bottom bar because the sheet scrolls: the actions stay put, and the sheet
    /// loses a whole band of chrome.
    private var header: some View {
        HStack(spacing: LoomTheme.Space.sm) {
            Toggle(isOn: $draft.isEnabled) { EmptyView() }
                .toggleStyle(.checkbox)
                .loomToggle()
                .labelsHidden()
                .accessibilityLabel("Rule enabled")
                .help(draft.isEnabled ? "This rule applies to matching traffic" : "Saved, but not applied")

            Text(isNew ? "New Rule" : "Edit Rule").font(.headline)

            Spacer()

            Button("Cancel", role: .cancel) { store.send(.delegate(.cancel)) }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .keyboardShortcut(.cancelAction)
            Button("Save") { save() }
                .buttonStyle(.plain)
                .foregroundStyle(LoomTheme.Palette.success)
                .fontWeight(.semibold)
                .keyboardShortcut(.defaultAction)
        }
        .font(.body)
        .padding(LoomTheme.Space.md)
    }

    @ViewBuilder private var errorBar: some View {
        if let error {
            HStack(spacing: LoomTheme.Space.xs) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(LoomTheme.Palette.warning)
                Text(error).font(.body).foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, LoomTheme.Space.md)
            .padding(.vertical, LoomTheme.Space.sm)
            .background(LoomTheme.Palette.warning.opacity(LoomTheme.attentionOpacity))
            .transition(.opacity)
        }
    }

    private func save() {
        switch draft.build() {
        case let .success(rule):
            store.send(.delegate(.save(rule, isNew: store.isNew)))
        case let .failure(failure):
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.15)) { error = failure.message }
        }
    }

    // MARK: Identity (group + name, then the note)

    private var identityRow: some View {
        VStack(alignment: .leading, spacing: LoomTheme.Space.sm) {
            LabeledField("Name") {
                HStack(spacing: LoomTheme.Space.xs) {
                    groupControl
                    LoomTextField(text: $draft.name, prompt: "Untitled")
                }
            }
            // Shown on the list row, so it has to be editable here — otherwise a
            // note an agent wrote is read-only to the human it was written for.
            LabeledField("Note") {
                LoomTextField(text: $draft.comment, prompt: "Optional — why this rule exists")
            }
        }
    }

    /// Editable group combo: type a new group, or pick an existing one from the menu.
    private var groupControl: some View {
        HStack(spacing: LoomTheme.Space.xxs) {
            LoomTextField(text: $draft.group, prompt: "No group")
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
                    .foregroundStyle(draft.group.isEmpty ? Color.secondary : LoomTheme.Palette.accent)
            }
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .frame(width: 18)
            .accessibilityLabel("Pick an existing group")
            .help("Pick an existing group")
        }
        .frame(width: 200)
    }

    // MARK: URL (methods + pattern + match-style chips)

    private var urlRow: some View {
        VStack(alignment: .leading, spacing: LoomTheme.Space.xxs) {
            HStack {
                Text("URL").font(.callout).foregroundStyle(.secondary)
                Spacer()
                // Always says which of the four matching styles is in force —
                // the default (prefix) is the one that surprises people, so it is
                // no longer the only one left unlabelled.
                Text(matchStyleText).font(.callout).foregroundStyle(.tertiary)
            }
            HStack(spacing: LoomTheme.Space.xs) {
                methodMenu
                HStack(spacing: LoomTheme.Space.xxs) {
                    LoomTextField(text: $draft.urlPattern, prompt: "https://api.example.com/*", mono: true)
                    // Regex and exact are mutually exclusive; enabling one clears
                    // the other so the model never carries both.
                    ChipToggle(
                        label: "=", isOn: draft.isExact,
                        help: draft.isExact
                            ? "Exact on — the URL must equal this pattern exactly"
                            : "Exact off — match the whole URL exactly"
                    ) {
                        draft.isExact.toggle()
                        if draft.isExact { draft.isRegex = false }
                    }
                    ChipToggle(
                        label: ".*", isOn: draft.isRegex,
                        help: draft.isRegex
                            ? "Regex on — matching the URL as a regular expression"
                            : "Regex off — glob/prefix matching"
                    ) {
                        draft.isRegex.toggle()
                        if draft.isRegex { draft.isExact = false }
                    }
                }
            }
            matchConditions
                // The parent stacks at `xxs`; this makes the gap above the row add
                // up to `sm` — the same rhythm as Name → Note, so the sheet has one
                // spacing between labelled rows rather than one per row.
                .padding(.top, LoomTheme.Space.xs)
        }
    }

    /// The four matching styles, named. A pattern with neither `*`, exact nor regex
    /// is a **prefix** match that ignores the query string — the default, and the
    /// one that silently matches more than people expect.
    private var matchStyleText: String {
        if draft.isRegex { return "Regex" }
        if draft.isExact { return "Exact match" }
        if draft.urlPattern.contains("*") { return "Wildcards" }
        return "Prefix match — also matches any query string"
    }

    /// Multi-select methods. The model holds a list and an agent routinely sets
    /// more than one; a single-select dropdown could only show the first, and
    /// saving replaced the whole set with it.
    private var methodMenu: some View {
        Menu {
            Button {
                draft.methods = []
            } label: {
                // A checkmark only when selected — an empty `systemImage` renders as
                // a missing-symbol placeholder rather than as nothing.
                if draft.methods.isEmpty { Label("Any method", systemImage: "checkmark") }
                else { Text("Any method") }
            }
            Divider()
            ForEach(methodChoices, id: \.self) { method in
                Button {
                    toggleMethod(method)
                } label: {
                    if draft.methods.contains(method) { Label(method, systemImage: "checkmark") }
                    else { Text(method) }
                }
            }
        } label: {
            HStack(spacing: LoomTheme.Space.xxs) {
                // Slack on both sides: the control is width-pinned (the label runs
                // from "ANY" to "3 methods" and the URL field beside it must not
                // shuffle), so the pair sits centred in the well rather than
                // hugging one edge with a hole at the other.
                Spacer(minLength: 0)
                Text(methodLabel)
                    .font(.body.monospaced())
                    .foregroundStyle(draft.methods.isEmpty ? Color.secondary : Color.primary)
                    .lineLimit(1)
                Image(systemName: "chevron.down").font(.caption2.weight(.semibold)).foregroundStyle(.tertiary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, LoomTheme.Control.fieldPaddingH)
            .padding(.vertical, LoomTheme.Control.fieldPaddingV)
            // Bordered like the URL field it shares the row with: two controls on
            // one line, one of them in a well and the other bare, reads as one of
            // them being disabled.
            .loomField()
            .contentShape(Rectangle())
        }
        // See `LoomPicker`: `.borderlessButton` reorders a custom label.
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .frame(width: 104)
        .help(draft.methods.isEmpty ? "Matches any HTTP method" : "Matches \(draft.methods.joined(separator: ", "))")
    }

    private var methodLabel: String {
        switch draft.methods.count {
        case 0: return "ANY"
        case 1: return draft.methods[0]
        case 2: return draft.methods.joined(separator: "/")
        default: return "\(draft.methods.count) methods"
        }
    }

    /// The well-known verbs, plus any custom one already on the rule so selecting
    /// something else doesn't make it unreachable.
    private var methodChoices: [String] {
        Self.methods + draft.methods.filter { !Self.methods.contains($0) }
    }

    private func toggleMethod(_ method: String) {
        if let index = draft.methods.firstIndex(of: method) { draft.methods.remove(at: index) }
        else { draft.methods.append(method) }
    }

    // MARK: Match conditions (host + origin + query predicates)

    /// A collapsible section header: title, chevron, then a summary badge of what
    /// is inside. Not a `DisclosureGroup` — its chevron is fixed on the leading
    /// edge, which put a second left-aligned column under rows whose own labels
    /// start at the margin. The chevron sits against the title (it belongs to the
    /// word it opens; the badge can grow or vanish), and the whole row is the
    /// target.
    private func disclosureHeader(_ title: String, isExpanded: Binding<Bool>, summary: String) -> some View {
        Button {
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.15)) {
                isExpanded.wrappedValue.toggle()
            }
        } label: {
            HStack(spacing: LoomTheme.Space.xxs) {
                Text(title).font(.callout).foregroundStyle(.secondary)
                Image(systemName: isExpanded.wrappedValue ? "chevron.down" : "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
                if !summary.isEmpty {
                    CapsuleBadge(text: summary, tint: LoomTheme.Palette.accent, hPadding: 5, vPadding: 1)
                        .padding(.leading, LoomTheme.Space.xxs)
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityValue(summary.isEmpty ? "none set" : summary)
    }

    /// Everything that is neither matching nor an action on the message itself.
    /// Collapsed by default: a delay is real but rare, and it was costing a
    /// full-width card at the top of every rule anyone ever opened.
    @ViewBuilder private var advancedSection: some View {
        disclosureHeader("Advanced", isExpanded: $showAdvanced, summary: draft.advancedSummary)
        if showAdvanced {
            HStack(spacing: LoomTheme.Space.xs) {
                LabeledField("Delay the response") {
                    HStack(spacing: LoomTheme.Space.xs) {
                        LoomTextField(text: $draft.delayMs, prompt: "none", mono: true).frame(width: 108)
                        Text("ms").font(.body).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.top, LoomTheme.Space.xxs)
            EditorHint("Holds the response back to reproduce a slow network. Blank is no delay.")

            Toggle("Don't capture matching traffic", isOn: $draft.dropFromCapture)
                .controlSize(.small)
                .padding(.top, LoomTheme.Space.xs)
            EditorHint(
                "The request still goes out and is answered normally — Loom just stops recording it. "
                + "Use it to keep a chatty SDK out of the capture. Nothing arriving while this is on "
                + "can be recovered, and it disappears from every surface, including an agent's reads."
            )
        }
    }

    @ViewBuilder private var matchConditions: some View {
        disclosureHeader("Match conditions", isExpanded: $showMatchConditions, summary: matchConditionsSummary)

        if showMatchConditions {
            VStack(alignment: .leading, spacing: LoomTheme.Space.sm) {
                LabeledField("Host") {
                    LoomTextField(text: $draft.hostPattern, prompt: "*.example.com — optional host glob", mono: true)
                }
                LabeledField("From app") {
                    LoomTextField(text: $draft.sourceApp, prompt: "bundle id or name — only this app's requests", mono: true)
                }
                LabeledField("From device") {
                    LoomTextField(text: $draft.deviceIP, prompt: "device IP — only this device's requests", mono: true)
                }
                VStack(alignment: .leading, spacing: LoomTheme.Space.xxs) {
                    HStack {
                        Text("Query predicates").font(.callout).foregroundStyle(.secondary)
                        Spacer()
                        GlyphButton(systemImage: "plus", help: "Add a query predicate") {
                            draft.queryItems.append(QueryItem(key: "", value: ""))
                        }
                    }
                    if draft.queryItems.isEmpty {
                        EditorHint("Every key here must be present in the URL query; a value of * means any value.")
                    }
                    ForEach($draft.queryItems) { $item in
                        HStack(spacing: LoomTheme.Space.xs) {
                            LoomTextField(text: $item.key, prompt: "key", mono: true)
                            Text("=").font(.body.monospaced()).foregroundStyle(.tertiary)
                            LoomTextField(text: $item.value, prompt: "value or *", mono: true)
                            GlyphButton(systemImage: "trash", help: "Remove this match condition",
                                        tint: LoomTheme.Palette.error) {
                                draft.queryItems.removeAll { $0.id == item.id }
                            }
                        }
                    }
                }
            }
            .padding(.top, LoomTheme.Space.xs)
        }
    }

    /// Compact "host · 2 query" summary so a collapsed group still shows it's set.
    private var matchConditionsSummary: String {
        var parts: [String] = []
        if !draft.hostPattern.trimmingCharacters(in: .whitespaces).isEmpty { parts.append("host") }
        let queries = draft.queryItems.filter { !$0.key.trimmingCharacters(in: .whitespaces).isEmpty }.count
        if queries > 0 { parts.append("\(queries) query") }
        if !draft.sourceApp.trimmingCharacters(in: .whitespaces).isEmpty { parts.append("app") }
        if !draft.deviceIP.trimmingCharacters(in: .whitespaces).isEmpty { parts.append("device") }
        return parts.joined(separator: " · ")
    }

    // MARK: Actions — segmented, additive

    /// Tab strip + its pane as one surface: no gap, no second rounded rectangle,
    /// the selected tab's underline being the only break in the hairline between
    /// them.
    private var actionsCard: some View {
        VStack(alignment: .leading, spacing: 0) {
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
        }
        // One fill for strip and pane, clipped once — the strip's hover wash and
        // the selected tab's underline run to the card's own rounded corners
        // instead of ending on an inner edge.
        .background(LoomTheme.Surface.group)
        .clipShape(RoundedRectangle(cornerRadius: LoomTheme.Radius.md, style: .continuous))
    }

    private var activeSegments: Set<ActionSegment> {
        var active: Set<ActionSegment> = []
        if !draft.requestSubs.filter({ !$0.isEmpty }).isEmpty { active.insert(.modifyRequest) }
        if draft.requestLineEdited || draft.requestHeadersEdited || draft.reqBodyOn { active.insert(.replaceRequest) }
        if !draft.responseSubs.filter({ !$0.isEmpty }).isEmpty { active.insert(.modifyResponse) }
        if draft.responseSource != .upstream || draft.responseLineEdited
            || draft.responseHeadersEdited || draft.respBodyOn {
            active.insert(.replaceResponse)
        }
        if draft.redirectOn { active.insert(.redirect) }
        return active
    }

    private static func firstActive(in draft: RuleDraft) -> ActionSegment? {
        if !draft.requestSubs.filter({ !$0.isEmpty }).isEmpty { return .modifyRequest }
        if draft.requestLineEdited || draft.requestHeadersEdited || draft.reqBodyOn { return .replaceRequest }
        if !draft.responseSubs.filter({ !$0.isEmpty }).isEmpty { return .modifyResponse }
        if draft.responseSource != .upstream || draft.responseLineEdited
            || draft.responseHeadersEdited || draft.respBodyOn {
            return .replaceResponse
        }
        if draft.redirectOn { return .redirect }
        return nil
    }

    // MARK: Replace Request — line / headers / body, one sub-tab each

    @ViewBuilder private var replaceRequestSection: some View {
        SubSegmentBar(
            selection: $requestPart,
            items: MessagePart.allCases.map { ($0, $0.label(request: true)) },
            active: activeRequestParts
        )
        switch requestPart {
        case .line:
            HStack(alignment: .top, spacing: LoomTheme.Space.sm) {
                LabeledField("Method") {
                    LoomTextField(text: $draft.reqMethod, prompt: "keep", mono: true).frame(width: 110)
                }
                LabeledField("URL") {
                    LoomTextField(text: $draft.reqURL, prompt: "keep — or a whole replacement URL", mono: true)
                }
            }
            EditorHint("Blank leaves the client's own. A URL here replaces the whole thing, unlike Redirect, which swaps the origin and keeps the path; the Host header follows it.")
        case .headers:
            HeaderEditor(title: "Set", text: $draft.reqSetHeaders)
            LabeledField("Remove") {
                LoomTextField(text: $draft.reqRemoveHeaders, prompt: "comma-separated names", mono: true)
            }
        case .body:
            bodySection(
                choice: requestBodyChoice,
                offersKeep: true,
                text: $draft.reqBody,
                keepHint: "The client's own body is forwarded unchanged."
            ) {
                switch draft.reqBodySource {
                case .empty:
                    EditorHint("Forwards a body of zero bytes — a different instruction from leaving the client's body alone (Keep, above).")
                // `.binary` is never offered here: a request body rewrite is text
                // or a file, so it falls in with text rather than being a state
                // this pane can show.
                case .binary, .text:
                    LoomTextArea(text: $draft.reqBody, minHeight: 140)
                case .file:
                    filePicker(path: $draft.reqBodyFile, hint: "Read at request time, so editing the file needs no rule change. If it can't be read, the client's own body is forwarded and the failure is logged.")
                }
            }
        }
    }

    private var activeRequestParts: Set<MessagePart> {
        var active: Set<MessagePart> = []
        if draft.requestLineEdited { active.insert(.line) }
        if draft.requestHeadersEdited { active.insert(.headers) }
        if draft.reqBodyOn { active.insert(.body) }
        return active
    }

    // MARK: Replace Response — a source, then the same three sub-tabs

    @ViewBuilder private var replaceResponseSection: some View {
        HStack(spacing: LoomTheme.Space.sm) {
            LoomLabeledPicker(
                label: "Source",
                selection: Binding(get: { draft.responseSource }, set: { draft.responseSource = $0 }),
                items: [
                    (.upstream, "From upstream"),
                    (.shortCircuit, "Short-circuit"),
                    (.block, "Block (403)"),
                ]
            )
            Spacer(minLength: 0)
        }

        switch draft.responseSource {
        case .upstream:
            EditorHint(draft.redirectOn
                ? "The redirected upstream is called, and what it returns is edited below."
                : "The real upstream is called — side effects and all — and what it returns is edited below.")
        case .shortCircuit:
            EditorHint("The upstream is never contacted: no side effects, no waiting, and the status, headers and body below are the whole response.")
        case .block:
            EditorHint("Refuses the request with 403 and a body naming this rule. Outranks every other route when several rules match.")
        }

        if let carried = draft.carriedResponseRewriteSummary {
            HStack(alignment: .top, spacing: LoomTheme.Space.xs) {
                Image(systemName: "info.circle").foregroundStyle(LoomTheme.Palette.accent)
                EditorHint("This rule also rewrites the response (\(carried)) on top of the synthesized one. It is kept as-is; switch the source to \"From upstream\" to edit it here.")
            }
        }

        if draft.responseSource != .block {
            SubSegmentBar(
                selection: $responsePart,
                items: MessagePart.allCases.map { ($0, $0.label(request: false)) },
                active: activeResponseParts
            )
            switch responsePart {
            case .line:
                LabeledField("Status") {
                    LoomTextField(text: $draft.respStatus, prompt: draft.responseSource == .shortCircuit ? "200" : "keep", mono: true)
                        .frame(width: 108)
                }
                EditorHint(draft.responseSource == .shortCircuit
                    ? "Blank means 200."
                    : "Blank leaves the upstream's status alone.")
            case .headers:
                HeaderEditor(title: "Set", text: $draft.respSetHeaders)
                LabeledField("Remove") {
                    LoomTextField(text: $draft.respRemoveHeaders, prompt: "comma-separated names", mono: true)
                }
            case .body:
                bodySection(
                    choice: responseBodyChoice,
                    // Nothing to keep when the response is synthesized: there is no
                    // upstream body to leave alone. Binary and file both mean the
                    // upstream is not called, so they only appear once it isn't.
                    offersKeep: draft.responseSource == .upstream,
                    offersBinary: draft.responseSource == .shortCircuit,
                    text: $draft.respBody,
                    keepHint: "The upstream's own body reaches the client unchanged."
                ) {
                    switch draft.respBodySource {
                    case .empty:
                        EditorHint("A response with no body.")
                    case .text:
                        LoomTextArea(text: $draft.respBody, minHeight: 140)
                        if draft.responseSource == .shortCircuit { contentTypeField(prompt: "application/json") }
                    case .binary:
                        LoomTextArea(text: $draft.respBodyBase64, minHeight: 140)
                        EditorHint("Base64, for a payload that isn't valid UTF-8 — an image, protobuf, gzip.")
                        contentTypeField(prompt: "application/octet-stream")
                    case .file:
                        filePicker(path: $draft.respBodyFile, hint: "Served instead of calling the upstream, read on every request.")
                        contentTypeField(prompt: "guessed from the file extension")
                    }
                }
            }
        }
    }

    private var activeResponseParts: Set<MessagePart> {
        var active: Set<MessagePart> = []
        if draft.responseLineEdited { active.insert(.line) }
        if draft.responseHeadersEdited { active.insert(.headers) }
        if draft.respBodyOn { active.insert(.body) }
        return active
    }

    /// A body sub-tab: the type row, then the editor for that type, with nothing
    /// in between.
    ///
    /// There is no "replace the body" switch any more, because the type picker
    /// already carries that bit: **Keep** is the off state, and it says what off
    /// *means* ("the upstream's body reaches the client unchanged") where a switch
    /// only said which control it belonged to. One control, four states, and the
    /// editor is visible the moment you pick a type rather than after two clicks.
    @ViewBuilder private func bodySection(
        choice: Binding<BodySource?>,
        offersKeep: Bool,
        offersBinary: Bool = false,
        text: Binding<String>,
        keepHint: String,
        @ViewBuilder editor: () -> some View
    ) -> some View {
        VStack(alignment: .leading, spacing: LoomTheme.Space.xxs) {
            HStack(spacing: LoomTheme.Space.sm) {
                LoomLabeledPicker(
                    label: "Type",
                    selection: choice,
                    items: (offersKeep ? [(BodySource?.none, "Keep")] : [])
                        + [(.some(.empty), "Empty"), (.some(.text), "Text")]
                        + (offersBinary ? [(BodySource?.some(.binary), "Binary (base64)")] : [])
                        + [(.some(.file), "Local file")]
                )

                Spacer(minLength: 0)

                // Trailing, on the row directly above the field it formats — the
                // action belongs to that box, so it sits against it rather than
                // inside it (where it was a second place to look).
                if choice.wrappedValue == .some(.text) {
                    let json = JSONValue.parse(Data(text.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).utf8))
                    GlyphButton(
                        systemImage: "curlybraces",
                        help: json == nil ? "Format — the body isn't JSON" : "Format the JSON, preserving key order",
                        isEnabled: json != nil
                    ) {
                        if let json { text.wrappedValue = json.prettyPrinted() }
                    }
                }
            }
            if choice.wrappedValue == nil {
                EditorHint(keepHint)
            } else {
                editor()
            }
        }
    }

    /// `nil` is Keep — the section being off. Reading and writing one draft flag
    /// plus one source, so the picker can't get into a state `build()` disagrees
    /// with.
    private var requestBodyChoice: Binding<BodySource?> {
        Binding(
            get: { draft.reqBodyOn ? draft.reqBodySource : nil },
            set: { newValue in
                guard let newValue else { draft.reqBodyOn = false; return }
                draft.reqBodyOn = true
                draft.reqBodySource = newValue
            }
        )
    }

    private var responseBodyChoice: Binding<BodySource?> {
        Binding(
            get: {
                // A synthesized response with no body reads as Empty rather than as
                // a missing choice: there is no upstream body it could be keeping.
                if draft.respBodyOn { return draft.respBodySource }
                return draft.responseSource == .upstream ? nil : .empty
            },
            set: { newValue in
                guard let newValue else { draft.respBodyOn = false; return }
                draft.setResponseBodySource(newValue)
            }
        )
    }

    /// Content-Type for a synthesized response. A shortcut, not a second source
    /// of truth: an explicit `Content-Type` in the Headers sub-tab wins over it
    /// (`RuleApplyingForwarder.synthesize` only appends this one when the headers
    /// don't already carry one), and the hint says so rather than leaving two
    /// controls for one header with the precedence in the code.
    private func contentTypeField(prompt: String) -> some View {
        LabeledField("Content-Type") {
            HStack(spacing: LoomTheme.Space.xs) {
                LoomTextField(text: $draft.respContentType, prompt: prompt, mono: true)
                    .frame(width: 260)
                Menu {
                    Button("Clear") { draft.respContentType = "" }
                    Divider()
                    ForEach(Self.contentTypes, id: \.self) { type in
                        Button(type) { draft.respContentType = type }
                    }
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Common content types")
                .accessibilityLabel("Pick a common content type")
                Spacer(minLength: 0)
            }
        }
    }

    /// The handful worth one tap. Not a closed list — the field stays typeable,
    /// because a mock of a real API routinely needs something not on it
    /// (`application/vnd.api+json`, a charset parameter, a protobuf subtype).
    private static let contentTypes = [
        "application/json",
        "text/plain; charset=utf-8",
        "text/html; charset=utf-8",
        "application/xml",
        "application/octet-stream",
        "image/png",
        "image/jpeg",
        "text/event-stream",
    ]

    private func filePicker(path: Binding<String>, hint: String) -> some View {
        VStack(alignment: .leading, spacing: LoomTheme.Space.xxs) {
            HStack(spacing: LoomTheme.Space.xs) {
                LoomTextField(text: path, prompt: "/Users/me/fixtures/home.json", mono: true)
                LoomButton(title: "Choose…") { chooseFile(into: path) }
            }
            EditorHint(hint)
        }
    }

    private func chooseFile(into path: Binding<String>) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { path.wrappedValue = url.path }
    }

    @ViewBuilder private var redirectSection: some View {
        sectionToggle("Redirect to another URL", isOn: $draft.redirectOn)
            .disabled(draft.routeClaimedElsewhere)
        if draft.routeClaimedElsewhere {
            EditorHint("Replace Response currently owns this rule's route (\(routeOwnerName)) — set its source back to \"From upstream\" to redirect instead.")
        } else if draft.redirectOn {
            LabeledField("Redirect to") {
                LoomTextField(text: $draft.redirectDest, prompt: "https://localhost:3000", mono: true)
            }
            LabeledField("Exclude URL (optional)") {
                LoomTextField(text: $draft.redirectExclude, prompt: "https://api.example.com/keep/*", mono: true)
            }
            Toggle("Keep Host header", isOn: $draft.keepHostHeader)
                .toggleStyle(.checkbox)
                .loomToggle()
                .font(.body)
                .help("The request's Host header stays unchanged instead of following the new origin.")
        } else {
            EditorHint("Send matching requests to a different scheme / host / port, keeping the path + query. The upstream is still called, so response edits above still apply.")
        }
    }

    private var routeOwnerName: String {
        switch draft.route {
        case .mock: return "Mock"
        case .mapLocal: return "Local file"
        case .block: return "Block"
        case .passthrough, .mapRemote: return "none"
        }
    }

    /// A section's on/off. A switch (not a checkbox) because it enables a whole
    /// block of controls rather than setting one option inside it — and always
    /// Loom's accent, never the user's system one.
    private func sectionToggle(_ title: String, isOn: Binding<Bool>) -> some View {
        Toggle(title, isOn: isOn)
            .toggleStyle(.switch)
            .controlSize(.small)
            .loomToggle()
            .font(.body.weight(.semibold))
    }

    private static let methods = ["GET", "POST", "PUT", "DELETE", "PATCH", "HEAD", "OPTIONS"]
}
