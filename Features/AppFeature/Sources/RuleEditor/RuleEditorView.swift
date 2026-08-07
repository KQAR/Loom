import ComposableArchitecture
import LoomSharedModels
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
    /// Match-conditions group starts expanded only when host/query/app/device are
    /// already set, so the common URL-only rule stays uncluttered — and a rule an
    /// agent scoped to one app opens showing that scope rather than hiding it.
    @State private var showMatchConditions: Bool

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
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(LoomTheme.Palette.warning)
                    Text(error).font(.callout).foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, LoomTheme.Space.md)
                .padding(.vertical, LoomTheme.Space.sm)
                .background(LoomTheme.Palette.warning.opacity(0.08))
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
            .accessibilityLabel("Pick an existing group")
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
                    Text("Regex enabled").font(.caption).foregroundStyle(LoomTheme.Palette.success)
                } else if draft.isExact {
                    Text("Exact match").font(.caption).foregroundStyle(LoomTheme.Palette.success)
                } else if draft.urlPattern.contains("*") {
                    Text("Wildcards enabled").font(.caption).foregroundStyle(LoomTheme.Palette.success)
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
                .loomSurface(LoomTheme.Surface.card)

                TextField("", text: $draft.urlPattern, prompt: Text("https://api.example.com/*"))
                    .textFieldStyle(.plain)
                    .font(.callout.monospaced())
                    .padding(.horizontal, LoomTheme.Space.sm)
                    .padding(.vertical, 6)
                    .loomSurface(LoomTheme.Surface.card)
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
                                    .foregroundStyle(draft.isExact ? LoomTheme.Palette.accent : Color.secondary)
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
                                    .foregroundStyle(draft.isRegex ? LoomTheme.Palette.accent : Color.secondary)
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
                LabeledField("From app") {
                    TextField("", text: $draft.sourceApp, prompt: Text("bundle id or name — only this app's requests"))
                        .textFieldStyle(.roundedBorder)
                        .font(.callout.monospaced())
                }
                LabeledField("From device") {
                    TextField("", text: $draft.deviceIP, prompt: Text("device IP — only this device's requests"))
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
                            .accessibilityLabel("Remove this match condition")
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
        if !draft.sourceApp.trimmingCharacters(in: .whitespaces).isEmpty { parts.append("app") }
        if !draft.deviceIP.trimmingCharacters(in: .whitespaces).isEmpty { parts.append("device") }
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
            .loomSurface(LoomTheme.Surface.group, radius: LoomTheme.Radius.md)
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
                        .loomField()
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
        .loomSurface(LoomTheme.Surface.group, radius: LoomTheme.Radius.md)
    }

    private func sectionHint(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private static let methods = ["ANY", "GET", "POST", "PUT", "DELETE", "PATCH", "HEAD", "OPTIONS"]
}
