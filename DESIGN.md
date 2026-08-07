---
version: 3.0
name: Loom-design-system
description: A native macOS status-bar debugging proxy with two human surfaces. The primary operator is an AI agent over MCP; the human uses a compact menu-bar CONSOLE for config & control (proxy on/off, system-proxy state, active rules, plus an Open Main Window button) and a MAIN WINDOW for the request list + per-flow detail. The console is a vibrant system material and shows no traffic; the main window is an opaque split layout (sidebar | detail). Color multiplies only for HTTP status; one accent carries interactivity and marks agent-replayed flows. Everything from the wire is SF Mono.

system-design:
  baseline: "pre-26 (macOS 14/15) — NOT Liquid Glass"
  how: "`UIDesignRequiresCompatibility: true` in the app's Info.plist (Project.swift)"
  why: "This spec's controls are macOS 14 controls (§ Known Gaps: .bordered / .borderedProminent, never .glass), and everything in the tree is drawn that way. What macOS 26 adds is SYSTEM chrome with no per-view opt-out — the shared-glass toolbar capsule that stretches when a .principal item is padded, and the NSScrollPocket band across the window top that survives titlebarAppearsTransparent and scrollEdgeEffectHidden. The key removes both, so the window matches this spec rather than the spec being rewritten around the OS."
  scope: "System control metrics revert with it (measured on 26.5: NSButton 37×24 → 47×32, NSTextField h 24 → 21, titlebar 32 → 28pt). Loom's OWN metrics do not move — sidebar 300, {spacing}, {rounded}, the 7pt capture dot are all unchanged, and no view code is tuned to either design."
  expiry: "Apple documents the key as temporary and intends to drop it after Xcode 26. When it stops working the glass chrome returns; that is a decision to re-make here — adopt it deliberately, per surface — not a build regression to chase."

colors:
  accent: "#007AFF"                # Color.accentColor — dark #0A84FF. Interactivity + "replayed by AI" marker.
  ink: "#000000D9"                 # Color.primary — dark #FFFFFFD9
  ink-secondary: "#0000008C"       # .secondary — dark #FFFFFF8C
  ink-tertiary: "#00000042"        # .tertiary — dark #FFFFFF42
  panel-material: "Material.menu"  # the popover background — vibrant system material, NEVER a hex.
  panel-selection: ".tint(.accent).opacity(0.12)"  # row hover/expand highlight inside the panel
  attention-fill: "{colors.accent}"   # attention-card tint at ~12% fill
  window-canvas: "#ECECEC"         # Main-window base — windowBackgroundColor, dark #282828
  window-content: "#FFFFFF"        # main-window code wells — controlBackgroundColor, dark #1E1E1E
  status-success: "#28CD41"        # 2xx — Color.green, dark #32D74B
  status-redirect: "#FF9500"       # 3xx — Color.orange, dark #FF9F0A
  status-error: "#FF3B30"          # 4xx / 5xx / transport error — Color.red, dark #FF453A
  status-pending: "#8E8E93"        # in flight, no response — Color(.systemGray)
  separator: "#0000001A"           # separatorColor — dark #FFFFFF1A. Row + section hairlines.
  on-accent: "#FFFFFF"

typography:
  headline:     { style: ".headline",     size: 13, weight: 600, use: "Panel header status, fault-card title" }
  body:         { style: ".body",         size: 13, weight: 400, use: "Default text, card reasons" }
  callout:      { style: ".callout",      size: 12, weight: 400, use: "Row metadata, section labels" }
  subheadline:  { style: ".subheadline",  size: 11, weight: 400, use: "Section headers (uppercased)" }
  mono:         { style: ".body.monospaced()",         size: 12, weight: 400, use: "URLs, headers, bodies, method glyph" }
  mono-small:   { style: ".callout.monospaced()",      size: 11, weight: 400, use: "Request-table host + method at list density" }
  numeric:      { style: ".callout.monospacedDigit()", size: 12, weight: 400, use: "Status codes, durations, port, count" }

rounded:
  sm: 6px          # row / card corners inside the console
  md: 10px         # fault cards, expanded-row container
  lg: 16px         # main-window code wells
  capsule: 9999px  # ALL buttons, status badges, method chips

spacing:
  xxs: 4px
  xs: 8px
  sm: 12px
  md: 16px         # panel internal padding
  lg: 20px         # main-window content margin

metrics:
  console-width: 300px       # the menu-bar popover (config & control only)
  main-window-default: 1040x640
  sidebar-width: 300         # category sidebar, fixed; also the collapse animation's travel, and the value MainView.sidebarWidth single-sources
  main-list-width: 320-520   # request list column (ideal 400)

components:
  # --- Status-bar console (popover) ---
  menu-panel:
    material: "{colors.panel-material}"
    width: "{metrics.console-width}"
    structure: "header (capture dot + address + proxy switch) · state rows (Connect Device / Reverse Proxies / System Proxy / HTTPS / SSL Scope / Client Certificates / Rules / Breakpoints — SSL Scope, Client Certificates and Breakpoints conditional, absent rather than empty) · Open Main Window · footer (version · wordmark · Quit)"
    note: "config & control only — NO request list here"
  config-row:
    anatomy: "one tappable full-width row: leading checkmark slot (accent, shown when the state is ON) · SF Symbol (secondary, 20pt) · title ({typography.body}) · trailing detail ({typography.callout} .tertiary). NO switch/toggle controls — the row toggles on tap and the checkmark is the state. Hover fills the row with {colors.panel-selection}."
    action-row: "same anatomy for non-state actions (e.g. Open Main Window): no checkmark, a trailing chevron.right instead of a detail. Keeps the panel one consistent, compact list."
  fault-card:
    backgroundColor: "{colors.status-error} @ ~12%"
    rounded: "{rounded.md}"
    anatomy: "SF Symbol + one-line fault · single fix action"
  # --- Main window (opaque content, frosted titlebar band) ---
  main-window:
    structure: "HStack(spacing: 0): sidebar | VSplitView(request-table top / inspector-panel bottom). Layout follows standard HTTP-debugger conventions (Proxyman/Charles-style). No sidebar/window title. NOT NavigationSplitView: it defeats the request table's row-view reuse and pays a quadratic AppKit KVO teardown on every sidebar switch — 8.7 s vs 143 ms measured at 2000 flows (CLAUDE.md § Known Issues). NOT HSplitView either: a bare NSSplitView has no collapse semantics, so the sidebar could only be inserted/removed (it pops), and its divider was already fixed and undraggable here. NOT an NSSplitViewController bridge: on macOS 26 a real .sidebar split item is a floating glass card inset 8pt and 40pt off the top, which is not this flush sidebar. Collapse animates the pane WIDTH 300↔0, trailing-aligned + clipped, so it pushes out rather than squashing; toolbar 'sidebar.left' button (.navigation placement) + ⌃⌘S share one animated action."
    defaultSize: "{metrics.main-window-default}"
    titlebar: "FROSTED, not opaque and not bare: the request table extends under the toolbar band and blurs beneath it. Content surfaces below stay opaque — the frost is the band only. NSVisualEffectView(material: .titlebar, blendingMode: .withinWindow, state: .active) at the BACK of the titlebar container, so toolbar items read crisply over it. .withinWindow is load-bearing: it samples the table below it in this window, where .behindWindow would blur the desktop and leave the rows crisp. NO baseline hairline (titlebarSeparatorStyle = .none, showsBaselineSeparator = false), no border, no shadow — the frost is the only separation. Two rejected: SwiftUI .toolbarBackground(.visible, for: .windowToolbar) is a no-op under .windowStyle(.hiddenTitleBar); titlebarAppearsTransparent = false gives AppKit's OPAQUE fill, not a translucent one."
    toolbar: "chip centred on the WINDOW via .principal — that is what .principal does in either system design, and shifting it onto the content pane was measured and rejected twice (padding the item stretched macOS 26's shared-glass capsule by the same amount; hiding that shared background made the toolbar render a full-width backdrop). The capsule itself is absent under {system-design}. Chip: status dot + LAN-IP:port (verbatim, no digit grouping) + three gray/green status toggles (System proxy 'globe' · SSL 'lock.shield' · Map/rewrite 'wand.and.stars'). Right (.primaryAction, flat): Record start/stop ('record.circle'/'stop.fill' + label) + Clear ('xmark.bin'). No search, no title. All icons 16pt with ≥26pt tap targets."
  sidebar:         # left column — categories
    style: ".listStyle(.sidebar)"
    anatomy: "All Flows · Errors · Replayed (each Label + system .badge count) · Section 'Hosts' — one Label per host (globe icon + .badge count). Selection scopes the table."
  request-table:   # top of the split — a multi-column SwiftUI Table
    columns: "status-dot (28, centered) · # capture-order ({typography.numeric} .tertiary) · App (icon) · Protocol (URL scheme — HTTP/HTTPS/WS/WSS — mono, secondary; the scheme, NOT the response's httpVersion, which describes Loom's own HTTP/1.1 upstream hop and would misreport an h2 client) · Method (mono) · Host (favicon + mono, secondary) · Path (mono, middle-truncated, + ↻ if replayed) · Time (numeric)"
    order: "chronological — oldest at top, newest at the bottom (log/terminal style)"
    tail-follow: "auto-scroll to the newest row as the list grows; a user scroll stops following, and scrolling back to the bottom resumes it (live-scroll notifications distinguish user gestures from programmatic scrolls)"
    selection: "single, drives the inspector below"
    row-context-menu: "right-click a row → Copy ▸ Host · Path · URL · as cURL (curl reconstructs method/headers/body)"
  status-dot:      # the table's status column
    anatomy: "a 9pt status-class color dot: green 2xx · orange 3xx · red 4xx/5xx/error · gray in-flight. Color is not the only signal — the numeric code is a tooltip and appears in the inspector Summary. Method is a separate ink column, never chromatic."
  seq-column:      # request order
    anatomy: "1-based capture order (#1 = first request), {typography.numeric} .tertiary. Global + stable per flow, independent of the current filter/sort."
  inspector-panel: # bottom of the split — Request | Response, referenced from Proxyman
    backgroundColor: "{colors.window-canvas}"
    visibility: "shown ONLY when a flow is selected; otherwise the table fills the whole pane"
    structure: "HSplitView — left Request pane, right Response pane, each with its own tab strip"
    requestPane: "tab strip [Summary · Raw · Headers(n) · Cookies(n, only if any) · Body · Diff(replays only)] + method badge + Replay button; a copyable URL bar below the tabs. Summary = key/value table (Status/Method/Code/Host/Duration/Started/Origin). Raw = request line + headers + body with a line-number gutter."
    responsePane: "tab strip [Raw(default) · Headers(n) · Cookies(n, only if any) · Body] + status badge + ✕ close (deselects). Raw = status line + headers + body with a line-number gutter."
    cookies-tab: "shown only when present — request from the `Cookie` header (name=value pairs), response from `Set-Cookie` headers (name/value + attributes). Rendered as the SAME aligned two-column table as Headers (one shared `KeyValueGrid`; titles Name/Value), so values line up in a column and can be read down. `Set-Cookie` attributes (Path/HttpOnly/SameSite/…) sit inside the value cell as a .tertiary caption line, not a third column: only responses have them, so a column would be dead space on every request pane. Names, values and attributes all selectable."
    body-copy: "Body panes (request + response) show a floating copy button pinned top-right that copies the whole body; flips to a checkmark briefly."
    body-json: "when a body parses as JSON (object/array, ≤200KB), Body renders a collapsible, syntax-highlighted tree (JSONView) preserving original key order — chevron nodes, keys .label, strings green, numbers orange, bool purple, null secondary; deep nodes start collapsed. Non-JSON / oversized falls back to the line-numbered raw view. Editor syntax colors are a deliberate exception to 'color only for status'."
    tabStrip: "text tabs, selected = semibold + 2pt accent underline (custom, not segmented)"
  button-primary:
    style: ".buttonStyle(.borderedProminent)"   # .glassProminent on macOS 26+
    rounded: "{rounded.capsule}"
  reveal-to-delete:
    use: "destructive removal of one row in a console list whose loss is NOT recoverable in place — client certificates (the key exists only in Loom's store). A reverse-proxy endpoint is recreatable from the form right below it, so its trash acts immediately and does NOT use this."
    anatomy: "the row's trash button slides the row aside by 76pt and reveals a red .borderedProminent Delete at the trailing edge, which acts IMMEDIATELY. Tapping the trash again puts it away; the row's leading edge is clipped, not drawn over the card padding. .snappy(0.18)."
    why: "The console is a MenuBarExtra popover, so it cannot present a dialog (see § console). The reveal IS the confirmation — the destructive button is unreachable without a deliberate first tap — so no second confirm, and no warning caption: an inline Cancel/Remove prompt was tried and at {metrics.console-width} it is two truncated buttons over four wrapped lines."
  empty-state:
    component: "ContentUnavailableView styling — never custom-built"
---

# Loom Design System

> **Authority**: the single source of truth for all Loom UI. Derived from Apple's HIG — **not**
> from Loom's current code. Where an existing view disagrees, the view is wrong: refactor toward
> the spec, never propagate legacy styling. **v3 splits the human UI into two surfaces**: a menu-bar
> **console** (config & control) and a **main window** (request list + detail). The status bar no
> longer shows traffic.

## Overview

The real operator is an AI agent over MCP (see [`INTERACTION.md`](INTERACTION.md)); the human gets two
surfaces with sharply separated jobs:

- **Status-bar console** — a compact 300pt popover of *config & control*: proxy on/off, system-proxy state,
  which rules are active, and an **Open Main Window** button. It shows **no traffic**. Vibrant system material.
- **Main window** — the *working surface*: a split layout (`HStack`; see main-window.structure for why neither `NavigationSplitView` nor `HSplitView`) — category sidebar (All /
  Errors / Replayed + per-host groups) | request list | per-flow detail (with Replay + diff). Opaque,
  resizable, opened from the console.

Nothing is custom-drawn when a system control exists: semantic colors, the stock SF Pro ladder, SF Mono
for anything from the wire, capsule controls, system materials. Loom should feel like a first-party macOS
utility — closer to the system's own controls than to a themed Electron tool.

**Key characteristics**

- **Config vs traffic split.** The status bar answers "what's configured / does anything need me?"; the
  main window answers "what flowed / what's in this request?" Never mix the two.
- **The console is vibrant material.** Background `{colors.panel-material}`; config rows sit on it directly
  (no opaque cards). The main window uses opaque content surfaces (`{colors.window-canvas}` / list).
- **One accent.** `{colors.accent}` carries every interactive signal *and* marks an agent-replayed flow.
- **Color = HTTP status, not decoration.** The only chromatic color in the list is the status class:
  green 2xx, orange 3xx, red 4xx/5xx/error, gray pending — always with the numeric code. **Method is not
  status**: it stays ink-colored on the row's second line.
- **Everything from the wire is monospaced.** URLs, headers, bodies, method glyphs, codes, durations.
- **System-first.** Semantic colors, Dynamic Type text styles, SF Symbols, system materials,
  `ContentUnavailableView`. Hexes here are reference renderings of semantic tokens, never literals in code.

## Colors

> **Rule #1**: never write a hex literal in SwiftUI. Each token names the semantic color to use; the hex
> pairs exist only so agents and designers can reason about contrast.

- **Accent** (`Color.accentColor`): prominent buttons (the `Approve`, the `Start` when stopped), selection,
  focus, and the `↻` glyph on an agent-replayed flow. Loom respects the user's system accent.
- **Ink ladder** (`.primary` / `.secondary` / `.tertiary`): text and metadata inside the vibrant panel —
  the hierarchical styles are *vibrancy-aware* and adapt to the material automatically. Never manual opacity.
- **Panel material** (`{colors.panel-material}`): the popover background. A system menu/vibrant material —
  it has no hex and must never be simulated with a translucent fill. Rows and sections sit on it transparently.
- **Attention fills**: fault cards tint at ~12% `{colors.status-error}` — just enough to lift them off the
  rows, still translucent over the material.
- **Main-window surfaces** (opaque, window-only): `{colors.window-canvas}` base, `{colors.window-content}`
  for code wells. These exist *only* in the main window; the console has no opaque surfaces.
- **Status** — the four HTTP voices, the only sanctioned non-accent chromatic color:

  | Class | Token | System color | Applies to |
  |---|---|---|---|
  | 2xx | `{colors.status-success}` | `Color.green` | status badge |
  | 3xx | `{colors.status-redirect}` | `Color.orange` | status badge |
  | 4xx / 5xx / error | `{colors.status-error}` | `Color.red` | status badge; `error` flows; fault cards |
  | in flight | `{colors.status-pending}` | `Color(.systemGray)` | badge shows `ProgressView` |

- **Hairlines** (`separatorColor`): 1px separators between rows and sections — the console's only
  structure. No borders, **no gradients, ever**; depth is the material plus surface change.

## Typography

- **UI text**: SF Pro via text styles only (`.headline` … `.caption`) — never `Font.system(size:)` for UI copy,
  so Dynamic Type and the Display/Text optical switch keep working.
- **Wire text**: SF Mono via `.monospaced()` for URLs, headers, bodies, method glyphs; `.monospacedDigit()`
  for status codes, durations, port, count.
- **Densities differ by surface**: the console uses `.body`/`.callout` for config rows; the main list uses
  `{typography.mono}` (path) over `{typography.mono-small}` (method·host).
- **Weight ladder is 400 / 600.** Regular for reading, semibold for status pills and section titles via
  `bold()`. No scattered `fontWeight()`.
- **Hierarchy by ink, not size.** A list row is a primary path over a tertiary `METHOD · host`, not three sizes.
- **Truncate, don't wrap.** Paths middle-truncate with `.lineLimit(1)`; full text lives in the detail pane.

## Layout

### Status-bar console — a fixed `{metrics.console-width}` popover

```
┌─ ● 127.0.0.1:9090            [◉] ──┐   header: capture dot + address + proxy switch
│    SOCKS5 127.0.0.1:9091            │   second listener, only while it is bound
│ 📱 Connect Device            2      │   action-row (phone onboarding)
│ ⇄  Reverse Proxies           2      │   action-row, icon accent while any exist
│ 🌍 System Proxy      in use by …    │   config-row (three-valued: loom/off/other)
│ 🔒 HTTPS (SSL)       decrypting     │   config-row
│ ☰  SSL Scope         all but 2      │   action-row, conditional — expands a card
│    ▸ 2 hosts passed through …       │   inside the card: the glob lists, collapsed
│ 🔑 Client Certificates       1      │   config-row, conditional — expands a card
│ ⚙︎ Rules             2 active       │   config-row
│ 🛑 Breakpoints       1 held         │   config-row, conditional (orange)
│ ──────────────────────────────────  │
│ 📋 Open Main Window     N flows     │   action-row
│ v0.0.14  Loom                Quit   │   footer
└──────────────────────────────────────┘
```

The address block is the two *global* listeners: the proxy address, and the SOCKS
listener while it is bound. Reverse-proxy endpoints are **not** listed here — they are
per-origin, they carry state (listening or not) and actions (remove), and none of that
fits a caption line. They live entirely in the Reverse Proxies row below, which is the
one place they are reported, agent-created ones included: this list's other writer is
an agent, and two renderings of it meant two things to keep in step.

**Reverse Proxies** is an `action-row`, never a `config-row`, because there is nothing
here to toggle: endpoints are added and removed one at a time, and the console's only
switch stays the proxy on/off in the header. It sits **above** System Proxy — it is the
way in that works when that row can't help, for a client which ignores the system proxy
setting entirely. The row exists because creating one is the human's job even though an
agent can also do it: an endpoint is a listening port whose number goes into a dev
server's config file, and only the human edits that file. Its icon is accent while any
endpoint is configured — an action-row has no checkmark slot, so the icon is the only
thing that can say "something is set up here" (same highlight as Connect Device). The
trailing detail is the count, or a not-listening count in orange, which also takes the
icon: a fault has to read as a fault rather than as an active feature — an endpoint whose port didn't bind is
experienced by its client as connection refused, i.e. as Loom being down.

Its card's leading edge lines up with the **row's icon**, not with the panel margin — a
card belongs to the row above it and must not start further left than anything in it. The
card is the list (local URL, selectable, over `→ upstream`; no per-row icon, since the
row's own icon already says what these are and the one state an icon would carry —
not listening — is in the caption in words and in orange, where it can name the reason;
faults first, capped at 6 with the rest collapsed into a count) followed by a bottom-right **`plus` glyph**
(borderless, no label — the card's only content is the list, so the position already
says what is being added; the tooltip and accessibility label carry the words), which
swaps in the form. It trails the list rather than heading it: the list is what the card
is for.

The form is **one line** — `port` → `upstream`, joined by an `arrow.right` — because
that is what an endpoint is; two stacked fields made the reader assemble the
relationship. Below it, one live caption: the first problem with what has been typed
(orange), or the "blank picks a free port" hint while the port is empty. **No Label
field**: a label only disambiguates two endpoints on one host, which doesn't earn a
third input on a 300pt panel — an agent can still set one, and the list renders it.
Validation is live and defers to the engine's own `normalizedUpstream`, so the form and
`create_reverse_proxy` cannot disagree about what a usable upstream is. Cancel/Add sit
bottom-right, Add prominent and disabled until the upstream is valid. A removal is confirmed — whatever still names that port starts getting
connection refused, and Loom cannot undo that from here.

**SSL Scope** is an `action-row` under HTTPS, for the same reason Reverse Proxies is
one: there is nothing to toggle — the switch above already carries on/off — and what
this row holds is two lists. The scope decrypts everything by default, so the
informative half is what is *not* being read: the trailing detail is `all but 2`, and
then `· N unread` for origins going unread that nobody asked for. That second number is
the load-bearing one — the only hint on a collapsed console that a capture is thinner
than it looks — and it deliberately excludes deliberate pass-throughs, which also means
the icon only goes orange for something unexpected. A row that flagged the configuration
working would train the reader to ignore it.

Its card leads with the seen-not-decrypted list (host, then reason · connections · port
in a caption, with **Decrypt**, and a `xmark` for "never" only on rows that weren't
already excluded), capped at 6 like Reverse Proxies with the same accounting for what the
engine's 256-host bound dropped. The two glob lists sit **behind one disclosure line**
(`2 hosts passed through · everything else decrypted`), because they grow while the list
above them shrinks: an intercepted host drops out of the tunnelled list, whereas the
pass-through list gains an entry every time something breaks. Collapsed, never absent —
removing an entry is the only way to start decrypting a carved-out host, and this card is
the only surface on which an agent's scope write becomes visible to the human. Opened, the lists are capped at 10 and drop from the *front*:
newest is written last, so the end is what someone who just changed something is looking
for. The single text field adds to the **pass-through** list, since under the default
scope an include entry does nothing; the include list itself is shown only when it says
something a reader can't already infer (i.e. not while it is the bare `*`).

Rows marked **conditional** are absent rather than empty: Breakpoints appears only
while something is armed or held, Client Certificates only while HTTPS is on or an
identity exists, Decrypted Hosts while HTTPS is on or anything was passed through (the
second half matters — interception being *off* is one of the reasons an origin goes
unread, so the row has to be able to appear while the switch is off). A row that is always visible but usually says "none" spends the
console's scarcest resource — vertical space — on nothing.

Cards appear directly under the row they belong to (root-CA trust under HTTPS, the
client-certificate and reverse-proxy lists under their own rows) rather than in a fixed
slot, so the control and its detail read as one unit.

**Nothing in the console may present its own window** — no `confirmationDialog`, no
`sheet`, no `alert`. The console is a `MenuBarExtra` popover and it closes the moment it
stops being the key window, which is exactly what presenting takes: the dialog's buttons
end up unclickable and the orphaned dialog is still waiting when the panel is next
opened. (A file picker is the one unavoidable exception, because choosing a file needs a
real window.)

A destructive row action is therefore guarded — or not — by how expensive the mistake is,
never by a dialog:

- **Recreatable in place → the trash acts immediately.** A reverse-proxy endpoint is two
  fields in the form directly below it, and its own row says what they were, so any
  guard costs more than the mistake.
- **Not recoverable → `{components.reveal-to-delete}`.** A client certificate's key
  exists only in Loom's store; removing it means finding the original `.p12` again. Its
  trash slides the row aside to reveal a red **Delete** at the trailing edge, and that
  reveal *is* the confirmation — the destructive button is unreachable without a
  deliberate first tap.

An inline warning caption plus Cancel/Remove was tried for both and rejected on sight: at
300pt that is two truncated buttons over four wrapped lines for a one-word decision.

### Main window — sidebar + vertical split (standard debugger layout)

```
┌───────────────┬─────────────────────────────────────────────┐
│ Sidebar       │   ● 10.0.11.196:9090 🌐 🛡 🪄    ▶ Record  🗑 │  toolbar
│ All Flows  6  ├─────────────────────────────────────────────┤
│ Errors     2  │  ●  Method  Host        Path         Time    │  request-table
│ Replayed   0  │  200 GET    127.0.0.1   /api/users   12ms    │  (columns)
│ ▸ Hosts       │  404 GET    127.0.0.1   /api/missing  9ms    │
│   127…     3  ├───────────────── drag ──────────────────────┤
│   local…   3  │  GET /api/users            [Replay]          │  inspector-panel
│ 180–300       │  [Summary][Request][Response][Diff]          │  (tabbed)
│               │  … tab content …                            │
└───────────────┴─────────────────────────────────────────────┘
```

- **Console** is vibrant material, fixed width, non-scrolling (config is short). No traffic.
- **Sidebar** (`.listStyle(.sidebar)`): fixed categories (All / Errors / Replayed) with `.badge` counts, then a
  `Hosts` section — selection scopes the table.
- **Content**: with no selection, the `Table` fills the whole pane. Selecting a row reveals a `VSplitView` —
  table on top, tabbed `inspector-panel` below (draggable divider); the inspector's ✕ (top-right) closes it by
  deselecting.
- **Toolbar band is frosted** (`{components.main-window}.titlebar`): the request table extends under it and
  blurs beneath it — no hairline, no border, no shadow. Everything below the band stays opaque.
- **Toolbar**: a centered chip — status dot + `LAN-IP:port` + three gray/green status toggles (System proxy,
  SSL, Map/rewrite); right-aligned flat buttons `Record` (start/stop) + `Clear` (`xmark.bin`), with the macOS 26
  shared-glass container hidden. No search, no window title. System-proxy/SSL are M2, Map/rewrite and Record
  (interception) are M2/M3 — UI wired now, engines later.
- **Spacing**: base 4pt; console internal padding `{spacing.md}`. If a value isn't a token, it's probably wrong.

## Elevation & Depth

| Level | Treatment | Use |
|---|---|---|
| Console | System vibrant material + automatic popover shadow | the menu-bar surface |
| In-console content | Transparent config rows; ~12% tint for fault cards | console |
| Window content | Opaque semantic surface, hairlines, system list selection | main window list + detail |
| Overlay | Sheet with system background | cert-setup wizard (M2), confirmations |

Loom never draws a manual `.shadow()` — the only shadow is the system's under the popover/window. In the
console, depth is the material plus tint; do not stack opaque cards on it. Never simulate the material with
`Color.white.opacity(n)` — Reduce Transparency must swap it automatically.

## Shapes

| Token | Value | Use |
|---|---|---|
| `{rounded.sm}` | 6px | status pill, list hover |
| `{rounded.md}` | 10px | fault cards |
| `{rounded.lg}` | 16px | detail-pane code wells |
| `{rounded.capsule}` | ∞ | all buttons |

**Capsule = control, rounded-rect = container.** `RoundedRectangle` is always `.continuous`.

## Brand mark

**`loom.mark`** — a custom SF Symbol, not a system one: an **outlined window
sitting on a bus, with a node where it meets the line**. A client whose traffic
passes through one point, which is what Loom is. Original artwork — no
third-party asset is used or owed attribution.

It ships as a variable template (Ultralight / Regular / Black; SF Symbols
interpolates the rest) in `App/Resources/Assets.xcassets`, so it tracks font
weight and scale like any system symbol. **Template rendering only** — the menu
bar reads alpha and discards color.

The artwork is **generated, not hand-drawn**: `Tools/symbol-template/build.py`
(geometry in `mark.py`) emits both symbol sets. Retune the mark there and re-run;
never hand-edit the baked path data in the `.symbolset`.

Two variants, and the difference carries state rather than decoration:

| Symbol | Meaning |
|---|---|
| `loom.mark` | hollow node — traffic passes through untouched |
| `loom.mark.intercept` | solid node — traffic is being acted on (map / rewrite rules active) |

**Identity lives in the glyph, state lives in the modifiers.** Don't add a third
glyph for a third state — the menu-bar label already spends color on system-proxy
(yellow) and opacity on stopped.

Constraints for any future edit, each one learned by rendering it at size and
rejecting what failed:

- It is read at **18pt as a silhouette**, so the budget is a handful of strokes.
- **Outline, never fill.** Template rendering keeps only alpha: a filled body
  collapses into a solid block, and inverts to a glaring white one on a dark menu
  bar. This is what rules out most stock icon artwork wholesale.
- **No container.** A disc or plate around the glyph is the heaviest possible
  silhouette and reads as foreign beside the line glyphs it sits next to.
- Pin the visual extents to one box (x 6–94, y 8–92 in the design space) so every
  weight shares a bounding box.
- **Flatten every arc to a fixed chord count** (`build.py`). Left as arcs, CoreUI
  subdivides them by radius, the three weights end up with different segment
  counts, the interpolation has no point correspondence, and the compiled symbol
  **silently fails to decode** — `actool` succeeds, the app builds, `Image(_:)`
  has no compile-time check, and the icon is just gone. Nothing upstream reports
  it.
- Therefore: **`Tools/symbol-template/check.py` is the pass condition**, not a
  clean build. It compiles the catalog and asks a real bundle for each symbol
  back. Run it after any retune — and CI's build job runs it too, so a symbol
  that stops resolving fails the PR instead of shipping an invisible icon.

## Components

### Status-bar console

- **`menu-panel`** — the console. Vibrant material, `{metrics.console-width}` wide: header (status) → config
  rows → `Open Main Window` → footer. **No traffic.**
- **`config-row`** — anatomy per `{components.config-row}`: one tappable full-width row, leading checkmark
  slot (accent, shown when ON) · SF Symbol (secondary, 20pt) · title (`{typography.body}`) · trailing detail
  (`{typography.callout}` `.tertiary`). **No switch/toggle controls in rows** — the row toggles on tap and
  the checkmark is the state; the console's only switch is the proxy on/off in the header.
- **`fault-card`** — ~12% red fill: SF Symbol + one-line fault + a single fix action, above the config rows.

### Main window

- **`main-window`** — `HStack` (not `NavigationSplitView`, not `HSplitView` — see main-window.structure above): `sidebar` | `VSplitView(request-table, inspector-panel)`. Opaque
  content surfaces under a **frosted toolbar band** (`{components.main-window}.titlebar` — the table slides
  under it and blurs, with no hairline, border or shadow), no sidebar/window title. Toolbar per
  `{components.main-window}.toolbar` — centered status chip, Record + Clear right-aligned, no search field.
- **`sidebar`** (`.listStyle(.sidebar)`) — `All Flows` / `Errors` / `Replayed` as `Label`s with system
  `.badge` counts, then a `Hosts` section (one `Label` per host, globe + `.badge`). Selection scopes the table.
- **`request-table`** — a SwiftUI `Table` (resizable columns, single selection): status-pill · Protocol · Method · Host ·
  Path (middle-truncated, `↻` accent glyph if replayed) · Time. Everything from the wire is mono.
- **`status-pill`** — the status column, 44×20 fixed: 3-digit code in `{typography.numeric}` semibold,
  status-class color 100% text / ~15% fill; `ERR` for transport errors; a small `ProgressView` while in flight.
- **`inspector-panel`** — the bottom pane, opaque, shown only when a flow is selected. An `HSplitView` split into
  **Request** (left) and **Response** (right), each with its own text tab strip (selected tab = semibold + 2pt
  accent underline). Tab sets, badges and per-pane chrome per `{components.inspector-panel}.requestPane` /
  `.responsePane` — the YAML is the authority; don't restate the tab lists in prose. **Replay lives here** (the
  Request pane's Replay button, same write path as the agent). Layout referenced from Proxyman, not copied.
- **`empty-state`** — `ContentUnavailableView`: distinct copy for *proxy stopped* vs *running, nothing captured
  yet*. Never a custom illustration.

## Do's and Don'ts

**Do** — keep config in the console and traffic in the main window; use the vibrant material for the console and
opaque surfaces for the window; route interactivity through `{colors.accent}`; pair every status color with its
numeric code; monospace everything from the wire; use system sidebar `.badge` counts; test light/dark/
increased-contrast/Reduce-Transparency without code branches.

**Don't** — show the request list in the console or config in the window; present a dialog / sheet / alert from
the console (it closes the popover out from under itself — confirm inline in the row); put opaque white cards on
the console material; hardcode hex/RGB; add a second accent or any gradient; `.shadow()` manually; color the
method by status; fix UI font sizes with `Font.system(size:)`; nest cards; let AI-slop in (emoji in UI copy, an
SF Symbol on every label).

## Iteration Guide

1. Change ONE component at a time; reference its YAML key (`{components.fault-card}`) in commits/reviews.
2. New states of a component are new YAML entries with a `-suffix`, not prose forks.
3. Use `{token.refs}` in specs and a `DesignTokens` enum in code — never inline values.
4. Prefer deleting custom styling over adding it: the target is "system control + tokens + nothing else."

## Known Gaps

- **Pin/detach** is implemented (`PinController`): the header pin button re-hosts `PanelView` in a
  non-activating floating `NSPanel` (`level = .floating`, `becomesKeyOnlyIfNeeded`) over an
  `NSVisualEffectView(.popover)` so the vibrant material is preserved; the panel's close button unpins.
  Gap: it opens at a fixed 380×560 top-trailing and isn't resizable yet.
- **Approval cards were cancelled, not deferred** (owner decision — see [`INTERACTION.md`](INTERACTION.md)
  § Guardrail): write tools act directly; supervision is the loopback boundary + audit trail. The former
  `approval-card` spec was removed with them; `fault-card` shipped and stays.
- Liquid Glass button styles (`.glassProminent`/`.glass`) are macOS 26-only; on the macOS 14 baseline use
  `.borderedProminent`/`.bordered`. That baseline is now what the app actually renders in — see
  `system-design` at the top of this file — so those styles would be inert here anyway. The brand mark is now specified (§ Brand mark) and shipping in the menu bar;
  the **app icon** is still unspecified and is the remaining branding gap.
