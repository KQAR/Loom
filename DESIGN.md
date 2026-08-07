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
  status-warning: "#FF9500"        # Color.orange — a fault the human can fix (a warning switch-tile, a
                                   # not-listening endpoint, an unreadable client identity, held traffic).
                                   # Same hue as {colors.status-redirect}, deliberately named apart: one is
                                   # a wire fact, this one is a console state, and they change for
                                   # different reasons. Yellow (Color.yellow) is its softer sibling and
                                   # means "waiting on you", not "broken".
  separator: "#0000001A"           # separatorColor — dark #FFFFFF1A. Row + section hairlines.
  on-accent: "#FFFFFF"

typography:
  headline:     { style: ".headline",     size: 13, weight: 600, use: "Panel header status, fault-card title" }
  body:         { style: ".body",         size: 13, weight: 400, use: "Default text, card reasons" }
  callout:      { style: ".callout",      size: 12, weight: 400, use: "Row metadata, section labels" }
  subheadline:  { style: ".subheadline",  size: 11, weight: 400, use: "Section headers (uppercased)" }
  caption:      { style: ".caption",      size: 10, weight: 400, use: "Console alert lines, sub-row lists under a config row, footer" }
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
  sm: 12px         # console horizontal margin ({metrics.console-margin}) — see LoomTheme.consoleMargin
  md: 16px         # main-window content padding
  lg: 20px         # main-window content margin

metrics:
  console-width: 272px       # the menu-bar popover (config & control only). Down from 300: nothing here is wide content — the widest line the console can produce is the `Client Certificates` title plus its longest state, and that state was shortened to two words rather than the panel kept wide for it. A popover reaching a third of the way across a laptop reads as a window that forgot to be one
  console-margin: 12px       # horizontal margin inside it — {spacing.sm}, NOT {spacing.md}: at this width a 16pt margin spends over a tenth of it on nothing, and every band competes for that width. One token (LoomTheme.consoleMargin) so a card can't drift wider than the row it hangs under
  main-window-default: 1040x640
  sidebar-width: 300         # category sidebar, fixed; also the collapse animation's travel, and the value MainView.sidebarWidth single-sources
  main-list-width: 320-520   # request list column (ideal 400)

components:
  # --- Status-bar console (popover) ---
  menu-panel:
    material: "{colors.panel-material}"
    width: "{metrics.console-width}"
    structure: "header (capture dot · address · Privileged Helper key · proxy switch) · switch-tile strip (System · HTTPS · Rules · Device) · console-alert channel (present only when something is wrong) · config rows (Reverse Proxies / SSL Scope / Client Certificates / Breakpoints — the last three conditional, absent rather than empty) · footer (version · Open Main Window + wordmark · Quit)"
    note: "config & control only — NO request list here"
    banding: "which band a control lands in is decided by ONE question: can its state be read off a three-value tint? Boolean → switch-tile. State that is a PHRASE (`all but 2 · 3 unread`, `1 need attention`, `2 not listening`) → config-row, which has room for words. No state worth a caption (a navigation, or the helper) → header-glyph. A control that outgrows its band moves band; a caption that starts reporting state is the tell that it should have."
  switch-tile:
    use: "the three structurally identical booleans — System Proxy, HTTPS, Rules — plus Connect Device, which is not a switch but reads as one member of the same question (how does traffic reach Loom). Nothing else, and Device never takes the warning tint."
    anatomy: "a 16pt semibold glyph over a {typography.caption} caption, equal thirds of the content width, NO background block, HStack spacing {spacing.xxs} (half a row's — four controls answering one question should read as one strip, not four adjacent buttons). The TINT of glyph AND caption is the state: OFF = .secondary · ON = {colors.accent} · WARNING = {colors.status-warning}. The only fill is the {rounded.md} hover highlight ({colors.panel-selection}) — an interaction state, not a display one. Optional count badge offset off the GLYPH's top-trailing corner (out of layout, so it cannot break the equal thirds) — only on a tile with something countable (Rules), never on a bare boolean, where a `1` would read as a quantity."
    caption: "names the control, NEVER its state — 'System', never 'System — on'. State is the tint's job, and a caption that repeated it would be a second truth to keep in step. Keep it to ONE short word: the strip is four columns at {metrics.console-width}/4 ≈ 56pt, which is why 'System Proxy' became 'System' — the unabbreviated name is in the tooltip. lineLimit(1) and NO minimumScaleFactor (see § Motion — it made the type jitter). The unabbreviated sentence lives in the tooltip AND in .accessibilityHint, so VoiceOver gets it too."
    warning-state: "ON but not doing its job — HTTPS with an untrusted root CA decrypts nothing; System Proxy that another app has taken routes nothing here. It is NOT the same as off, and it MUST be paired with a console-alert (or a fault-card, which is a richer form of one): a warning tile alone is a dead end, because the only thing you can do to it is the one thing that makes it worse."
    not-a-warning: "on-with-nothing-configured (Rules enabled, zero rules) stays ON. That is a fresh install, and orange there teaches the reader to ignore the colour — same rule as the SSL Scope row's `unread` count excluding deliberate pass-throughs."
  console-alert:
    use: "the channel that pays for the label-less strips: everything a fill or a glyph cannot say. Between the switch-tile strip and the config rows."
    anatomy: "one line: exclamationmark.triangle.fill (or a small ProgressView while busy) · {typography.caption} text in the tint · trailing chevron.right ONLY when tapping repairs something. Tinted {colors.status-warning}, or yellow for 'waiting on you', or .secondary while a change is in flight."
    rules: "ABSENT entirely when nothing is wrong — a healthy console must pay nothing for it. One warning source = one line. The text names the NEXT ACTION, not just the diagnosis. Tapping runs the repair, never the control's own action (which for a warning tile is 'turn the broken thing off'); when the repair is in another app, there is no chevron and the row is a statement."
  header-glyph:
    use: "the Privileged Helper on the address line — the only one. A control with no state worth a caption. Nothing here toggles. (Open Main Window is NOT one of these: it is the footer wordmark itself, glyph + word as a single button at {typography.caption}.)"
    anatomy: "a bare {typography.callout}-sized glyph (13pt, the row density — NOT the tile's 18pt, which would out-weigh the address it shares a line with), 18pt hit box, {rounded.sm} hover fill, no caption and no background. Tint is the whole state channel: .primary for Open Main Window (the highest-frequency action — secondary read as disabled beside the tinted glyphs), accent for armed, orange/yellow for faulty, secondary otherwise. Count badge offset OUT of layout, so a two-digit count cannot push the address into truncation."
    placement: "helper immediately after ip:port — it exists so pointing macOS at that listener stops costing a password prompt, so it belongs to the address, not to a strip. The address takes layoutPriority(1) so a long LAN IP shrinks the spacer, never itself."
    limit: "the helper's state needs a VERB (install / go approve / repair), which no glyph carries — so its two actionable states also take a console-alert line. A control needing that twice, or wanting a caption, belongs in a switch-tile or a config-row instead."
  config-row:
    anatomy: "one tappable full-width row: SF Symbol (secondary, 20pt, or tinted accent/orange to carry 'configured'/'faulty') · title ({typography.body}) · trailing detail ({typography.callout} .tertiary) · trailing glyph. Hover fills the row with {colors.panel-selection}."
    trailing-glyph: "REQUIRED, and it is the row's only promise about what a tap does: chevron.right (rotating to chevron.down when open) expands a card in place; arrow.up.right leaves the console. There is no ON/OFF row variant any more — the booleans are switch-tiles — so an untinted row is never ambiguous about being 'off'."
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
    anatomy: "All Flows · Errors · Rules · Audit · Breakpoints (each a Label + a TRAILING PLAIN COUNT — {typography.numeric} .tertiary, never .badge(): the pill is for attention, and these are bucket sizes on every row at once) · Sections 'Devices' / 'Apps' / 'Hosts', one Label per entry with the same trailing count. Selection scopes the table."
  request-table:   # top of the split — a multi-column SwiftUI Table
    columns: "status-dot (28, centered) · # capture-order ({typography.numeric} .tertiary, min 30 / ideal 38 / max 56 — sized for FIVE digits: the ring caps at 2000 and every extra point comes off Path, which is never wide enough) · App (icon) · Protocol (URL scheme — HTTP/HTTPS/WS/WSS — mono, secondary; the scheme, NOT the response's httpVersion, which describes Loom's own HTTP/1.1 upstream hop and would misreport an h2 client) · Method (mono) · Host (favicon + mono, secondary) · Path (mono, middle-truncated, + ↻ if replayed) · Time (numeric)"
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

- **Status-bar console** — a compact `{metrics.console-width}` popover of *config & control*: proxy on/off, system-proxy state,
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

- **Hairlines** (`separatorColor`): 1px separators between rows and sections — **main window only**.
  The console has none at all (§ console): its bands are shapes and padding, and a line between two
  things that already look different only costs height there. No borders anywhere, **no gradients,
  ever**; depth is the material plus surface change.

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
   ● 127.0.0.1:9090 🔑           [◉]     header: dot · address · helper key · proxy switch
     SOCKS5 :9091                        second listener — PORT ONLY, same host as above

     🌍       🔒      ⚙︎ ②      📱②      tile strip — tinted glyph over a caption
   System   HTTPS    Rules    Device     TINT = state: secondary off · accent on · orange warning

  ⚠ Another proxy app has it …  ›         console-alert — ABSENT unless something is wrong

  ⇄  Reverse Proxies        2        ›    config-row, icon accent while any exist
  ☰  SSL Scope    all but 2 · 3 unread ›  config-row, conditional — › expands a card
     ▸ 2 hosts passed through …           inside the card: the glob lists, collapsed
  🔑 Client Certificates    1        ›    config-row, conditional — › expands a card
  🛑 Breakpoints         1 held      ↗    config-row, conditional (orange) — ↗ leaves

   v0.0.19     🖥 Loom         Quit      footer — the wordmark IS the way into the main window
```

**The console draws no lines and no standing fills.** No `Divider`, no stroked tile, no
card border, and no filled block behind a glyph — the diagram above has none because the
surface has none. A tile is a tinted glyph over a caption; the only fill in the strip is
the hover highlight, which is an interaction state and not a display one. The bands are told apart by their
own shapes (a strip of tiles, a list of rows, a strip of glyphs) and by the padding
between them, which is enough; a hairline between two things that already look different
only adds density on the surface whose scarcest resource is height. This is a rule about
the console specifically — the main window still uses hairlines (§ Elevation).

**The header holds only what is about the listener itself.** The helper key sits
immediately after `ip:port` because that is what it is for — it exists so that pointing
macOS at *this* listener stops costing a password prompt. It is not a switch and not a
destination, which is why it is the only glyph up there.

**Connect Device is the strip's fourth member, and the only one that isn't a switch.** It
belongs with the three because it answers the same question they do — *how does traffic
reach Loom* — and it reads the same way: one glyph, one name, a tint saying whether it is
live. It must never take the `warning` tint: a fault it cannot repair belongs in the
alert channel, one it can belongs in a row.

**Open Main Window is the wordmark**, glyph and word as one control rather than a button
parked beside a label. The glyph takes the wordmark's own `{typography.caption}` — sized
to the text, not to a fixed metric — because at any larger size the two stop reading as
one object. The console's highest-frequency action is deliberately its quietest control:
everything above it is configuration you visit rarely, so it earns *position*, not weight,
and the footer is where the eye already ends up. Three placements were tried first (a
captioned bottom strip, which spent a whole band on two navigations; the header's trailing
edge, which put a destination in among the listener's own state) and this is the one that
costs no line at all.

**Which glyph morphs, which pulses, and why System Proxy does neither: § Motion.** The one
console-specific consequence: the alert channel carries **outcomes only**, never progress —
the System Proxy tile's pulse already says a change is in flight, and a spinner plus
"Setting system proxy…" underneath was the same fact twice on the surface where an
appearing line shoves everything below it.

**Nothing in the strip may move when something below it opens.** The tiles are pinned to
a fixed content height and their captions carry no `minimumScaleFactor` — that modifier
was there to protect a two-word caption and it made the type *jitter*, because expanding
a card re-lays out the panel and the scale factor is recomputed against transient widths.
A control that did not change must not appear to change. A caption that needs shrinking
to fit is a caption that is too long for this strip.

**A caption names the control; it never reports the control's state.** "System Proxy",
not "System Proxy — on": the tint says on, in three values, and a caption that also
carried state would be a second, wordier truth to keep in step with the first. This is
what keeps the strip from silently becoming a worse `config-row`.

**Two glyphs must never collide.** Open Main Window is `macwindow`, deliberately not
`list.bullet.rectangle`, which is the SSL Scope row's icon three rows above it. The
caption softens a collision but does not license one — check a new glyph against every
other glyph *currently on screen*, not just against the strip it joins.

**Three bands, and one question decides which band a control lands in: can its state be
read off a three-value tint?** System Proxy, HTTPS and Rules are structurally identical — one boolean
each — so they collapse into a strip where the *tint* of the glyph and its caption is the
state, in three values.
Everything whose state is a *phrase* (`all but 2 · 3 unread`, `1 need attention`,
`2 not listening`) keeps its words in a `config-row`, because no fill can say those.
Anything with no state worth a caption goes in the **header** as a bare glyph. A control
that outgrows its band **moves band**; it does not grow a label inside a label-less
strip, which would make the strip a worse version of a row.

The address block is the two *global* listeners: the proxy address, and — while it is
bound — the SOCKS listener as a **port alone**. Both listeners always bind the same
interface, so repeating the host made the header read as two addresses to compare rather
than one address with a second door; the indent under the host is what carries the
relationship, and the tooltip has the whole thing. Merging them onto one line was
measured and rejected: at a 20-character LAN address there is no room left beside the
key and the switch, and a line that only sometimes fits is a layout that jumps. Reverse-proxy endpoints are **not** listed here — they are
per-origin, they carry state (listening or not) and actions (remove), and none of that
fits a caption line. They live entirely in the Reverse Proxies row below, which is the
one place they are reported, agent-created ones included: this list's other writer is
an agent, and two renderings of it meant two things to keep in step.

**The console shows no captured count.** It was tried in the header next to the capture
dot and removed: the dot already answers the question this surface is for (*is Loom
recording?*), and a live number on a config surface pulls the eye to traffic, which is
the main window's job. The count is one click away there, on a surface that can show
*which* flows rather than only how many.

### The alert channel is what pays for the pure icons

A label-less strip is only affordable if everything a fill cannot say has somewhere to
go. That is the `console-alert` line between the strip and the rows, and it carries three
kinds of thing: a switch whose "on" is a lie (HTTPS interception on with an untrusted
root CA decrypts nothing), a switch whose "off" is a lie (System Proxy reads off while
another app routes the whole machine through itself), and a tool-strip glyph whose state
needs a verb (the privileged helper's install / go approve / repair).

Four rules, and the third is the load-bearing one:

- **Absent when nothing is wrong.** A healthy console pays zero lines for it. This is the
  whole trade — the strip saves rows only if its safety net is free in the ordinary case.
- **One warning source, one line.** Three at once is rare and not worth optimising for.
- **Tapping runs the repair, never the control's own action.** Tapping a warning HTTPS
  tile turns interception *off*, which is the opposite of what the reader wants; the
  alert line is the way to the fix. A warning tile with no alert beside it is a dead end
  and must not ship.
- **The text names the next action, not just the diagnosis.** "Another proxy app has the
  system proxy (127.0.0.1:8888) — quit it first; Loom won't put its settings back", not
  "in use". When the repair is in another app there is no chevron and the line is a
  statement — Loom does not offer a button it cannot honour.

A `fault-card` is the same idea at more length, and stands in for a line rather than
adding one: the CA-trust card already names the problem and carries the button, so the
warning HTTPS tile points at the card and the channel stays quiet.

**Two states are deliberately not warnings.** Rules on with zero rules is a fresh
install, not a fault; the privileged helper not being installed is an available option,
not a fault. Orange on either would teach the reader to ignore orange — the same
reasoning as the SSL Scope row's `unread` count excluding deliberate pass-throughs.

**A row title never wraps** (`lineLimit(1)`), and the widest row is what sets the panel's
width — not the other way round. When a state string stops fitting, shorten the *string*:
`1 need attention` became `1 broken` rather than the console staying 300pt wide for it. A
row that grows to two lines when a count changes is the height jitter § Motion exists to
prevent.

**Config rows must carry a trailing glyph**, and it is the row's only promise about what
a tap does: `›` (rotating to `⌄`) expands a card in place, `↗` leaves the console. Before
this, action rows drew no trailing glyph at all and were indistinguishable from a state
row that happened to be off — a row's whole affordance was something you had to remember.
With the booleans gone to the strip, there is no state row left to be confused with.

**Reverse Proxies** stays a row rather than becoming a header glyph because its state is a
phrase (`2 not listening`). It sits **above** the rest of the rows — it is the way in
that works when System Proxy can't help, for a client which ignores the system proxy
setting entirely. The row exists because creating one is the human's job even though an
agent can also do it: an endpoint is a listening port whose number goes into a dev
server's config file, and only the human edits that file. Its icon is accent while any
endpoint is configured — a row has no checkmark slot any more, so the icon is the only
thing that can say "something is set up here". The trailing detail is the count, or a
not-listening count in orange, which also takes the icon: a fault has to read as a fault
rather than as an active feature — an endpoint whose port didn't bind is experienced by
its client as connection refused, i.e. as Loom being down.

**Breakpoints stays a row too, and for a sharper reason**: `1 held` and `1 armed` are the
same number and wildly different urgencies, so a badge cannot stand in for the words.
Held traffic is a live client connection stalled by the AI.

**Rules keeps only its switch and its count here.** The enabled rules' *names* moved to
the main window's Rules panel: they used to be up to four permanently-visible lines whose
height was set by an agent's writes, on the surface whose scarcest resource is height.

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
third input on a panel this narrow — an agent can still set one, and the list renders it.
Validation is live and defers to the engine's own `normalizedUpstream`, so the form and
`create_reverse_proxy` cannot disagree about what a usable upstream is. Cancel/Add sit
bottom-right, Add prominent and disabled until the upstream is valid. A removal is confirmed — whatever still names that port starts getting
connection refused, and Loom cannot undo that from here.

**SSL Scope** is a `config-row` under the HTTPS tile, for the same reason Reverse Proxies
is one: there is nothing to toggle — the tile above already carries on/off — and what
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

Rows marked **conditional** are absent rather than empty (tiles never are — a switch that
vanishes is a switch you cannot turn on): Breakpoints appears only
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
this width that is two truncated buttons over four wrapped lines for a one-word decision.

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
- **Spacing**: base 4pt; console horizontal margin `{metrics.console-margin}` (12pt, narrower than the window's 16). If a value isn't a token, it's probably wrong.

## Motion

**Every interactive icon owes the reader feedback, and the feedback is animated.** A glyph
you can click is a control, and a control that changes silently is one the eye misses —
this applies on *both* surfaces, so the console's tiles and the main window's status chip
animate the same state with the same effect. Loom uses SF Symbol effects for this, never a
spinner alongside a glyph: a `ProgressView` next to a 16pt symbol breaks the one-glyph
rhythm of a strip and is a second, differently-shaped thing to read.

Three effects, three distinct meanings. Do not substitute one for another:

| Effect | Means | Fires |
|---|---|---|
| `.symbolEffect(.replace)` | **the state changed** | once, when the glyph itself changes shape |
| `.symbolEffect(.pulse, .repeating)` | **a write is in flight** | for as long as it is |
| hover fill (`{rounded.sm}`/`{rounded.md}` at `{colors.panel-selection}`) | **this is clickable** | on hover |

**`.replace` needs two glyphs to be a transition between.** Putting it on a control whose
symbol never changes is dead code that reads like a feature. So a state change **morphs
the glyph** wherever an honest pair exists — colour alone is not enough, and colour alone
fails outright for a reader who cannot distinguish the two hues. The pairs in use, all
same-family so the swap reads as one symbol becoming another rather than a different icon:

| Control | Off | On |
|---|---|---|
| HTTPS | `lock.shield` | `lock.shield.fill` |
| Rules | `wand.and.stars` | `wand.and.stars.inverse` |
| Connect Device | `iphone` | `iphone.radiowaves.left.and.right` |
| Privileged Helper | `key` | `key.fill` · `key.slash` when broken |
| Reverse Proxies | `arrow.left.arrow.right` | `arrow.left.arrow.right.circle.fill` |
| Client Certificates | `person.badge.key` | `person.badge.key.fill` |
| Breakpoints | `pause.circle` | `pause.circle.fill` |
| Record | `record.circle` | `stop.fill` |

**System Proxy is the deliberate exception, and its reason is the rule.** The `globe`
family has no fill or slash member, and every `network` substitute misstates the fact —
`network.slash` says "no network" when what happened is that another app owns the setting,
and `network.badge.shield.half.filled` is unreadable at this size. **A morph that means the
wrong thing is worse than a tint that means the right one.** Test a candidate pair against
the *worst* state it must describe, not the happy one — and verify the symbol exists at
runtime (`NSImage(systemSymbolName:)`); `Image(systemName:)` has no compile-time check, so
a typo ships as a blank.

Four constraints on all of it:

- **Reduce Motion is honoured, always** — every effect is gated on
  `accessibilityReduceMotion`, `.replace` degrading to `.identity`. A repeating effect that
  ignores it makes a menu-bar panel unusable.
- **A pulse is never the only signal.** It says *which* control is working, which a strip
  of four otherwise cannot — the outcome still arrives in words (a `console-alert` line, a
  `fault-card`). But the reverse also holds: once the pulse exists, a spinner-plus-sentence
  saying "…in progress" underneath is the same fact twice, on the surface where an
  appearing line shoves everything below it. Animate the progress, write only the outcome.
- **Busy disables taps but does not dim.** The control that is working is the one the eye
  should go to; `disabled`'s 0.5 opacity made the pulsing glyph the faintest thing on
  screen.
- **The same state animates the same way on both surfaces.** The console and the main
  window are two renderings of one store; a toggle that only animates in one of them
  teaches the reader that the other is frozen.

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

- **`menu-panel`** — the console. Vibrant material, `{metrics.console-width}` wide: header (status +
  `header-glyph`s) → `switch-tile` strip → `console-alert` channel → config rows → footer. **No traffic.**
- **`switch-tile`** — the strip (System · HTTPS · Rules · Device): a tinted glyph over a caption, no
  background block. The **tint** is the state (secondary off · accent on · `{colors.status-warning}` warning);
  the caption names the control and never its state. A warning tile must always be paired with a
  `console-alert` or a `fault-card`; see `{components.switch-tile}`.
- **`console-alert`** — the one line that carries what a fill or a glyph cannot say, and the repair with it.
  Absent when nothing is wrong. See `{components.console-alert}`.
- **`config-row`** — one tappable full-width row: SF Symbol (secondary 20pt, or tinted to carry
  configured/faulty) · title (`{typography.body}`) · trailing detail (`{typography.callout}` `.tertiary`) ·
  **required trailing glyph** — `chevron.right`/`chevron.down` expands a card in place, `arrow.up.right`
  leaves the console. **No switch/toggle controls in rows**; the console's only switch is the proxy on/off in
  the header, and its only tap-toggles are the tiles.
- **`header-glyph`** — a bare 13pt glyph with no caption and no fill: the Privileged Helper, right after
  `ip:port`. Tint carries armed/faulty; the verb is in the tooltip. Open Main Window is not one of these —
  it is the **footer wordmark**, glyph + word as one `{typography.caption}` button.
- **Console cards** (`ReverseProxyCard`, `ClientCertificatesCard`, `SSLScopeCard`) share one anatomy, because
  they hang off adjacent rows of the same 272pt panel and a bordered button on one beside a bare glyph on
  another reads as two different kinds of surface: `{spacing.sm}` padding on a `{rounded.sm}` `.quaternary`
  0.4 fill · the **list first** (it is what the card is for) · an empty-state sentence when there is none ·
  a bottom-right bare **`plus` glyph** (borderless, no label — the card's only content is the list, so the
  position already says what is being added; the tooltip and accessibility label carry the words), which
  swaps in the form · form buttons trailing-aligned, **Cancel then Add**, confirm last.
- **`fault-card`** — ~12% red fill: SF Symbol + one-line fault + a single fix action, directly under the tile
  whose warning it explains. It *replaces* that tile's alert line rather than adding to it.

### Main window

- **`main-window`** — `HStack` (not `NavigationSplitView`, not `HSplitView` — see main-window.structure above): `sidebar` | `VSplitView(request-table, inspector-panel)`. Opaque
  content surfaces under a **frosted toolbar band** (`{components.main-window}.titlebar` — the table slides
  under it and blurs, with no hairline, border or shadow), no sidebar/window title. Toolbar per
  `{components.main-window}.toolbar` — centered status chip, Record + Clear right-aligned, no search field.
- **`sidebar`** (`.listStyle(.sidebar)`) — `All Flows` / `Errors` / `Rules` / `Audit` / `Breakpoints` as
  `Label`s with a trailing count, then `Devices` / `Apps` / `Hosts` sections. The count is **plain tertiary
  monospaced digits, never `.badge()`**: AppKit's pill is right for "N things demanding attention" and wrong
  for a bucket size on every row at once, where a column of pills reads as a column of alerts. Monospaced so
  a count crossing 9→10→100 doesn't shift the row. Selection scopes the table.
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
numeric code; monospace everything from the wire; draw sidebar counts as plain tertiary digits, never `.badge()` pills; test light/dark/
increased-contrast/Reduce-Transparency without code branches.

**Don't** — signal a state change with colour alone when an honest same-family glyph pair
exists (§ Motion); ship a `.symbolEffect(.replace)` on a glyph that never changes; put a
progress sentence under a control that already pulses; let a `switch-tile` caption report state instead of naming the control (that is the tint's job,
and a control needing more than three values belongs in a `config-row`); reuse a glyph already on screen;
draw a `Divider`, a stroke, a border or a standing fill anywhere in the console; ship a warning tile with no `console-alert` or `fault-card` beside it; make a `console-alert`'s
tap run the control's own action instead of the repair; leave a `config-row` without its trailing glyph;
show the request list in the console or config in the window; present a dialog / sheet / alert from
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
