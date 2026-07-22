---
version: 3.0
name: Loom-design-system
description: A native macOS status-bar debugging proxy with two human surfaces. The primary operator is an AI agent over MCP; the human uses a compact menu-bar CONSOLE for config & control (proxy on/off, system-proxy state, active rules, plus an Open Main Window button) and a MAIN WINDOW for the request list + per-flow detail. The console is a vibrant system material and shows no traffic; the main window is an opaque NavigationSplitView (list | detail). Color multiplies only for HTTP status; one accent carries interactivity and marks agent-replayed flows. Everything from the wire is SF Mono.

colors:
  accent: "#007AFF"                # Color.accentColor — dark #0A84FF. Interactivity + "replayed by AI" marker.
  ink: "#000000D9"                 # Color.primary — dark #FFFFFFD9
  ink-secondary: "#0000008C"       # .secondary — dark #FFFFFF8C
  ink-tertiary: "#00000042"        # .tertiary — dark #FFFFFF42
  panel-material: "Material.menu"  # the popover background — vibrant system material, NEVER a hex.
  panel-selection: ".tint(.accent).opacity(0.12)"  # row hover/expand highlight inside the panel
  attention-fill: "{colors.accent}"   # approval/fault card tint at ~12% fill
  window-canvas: "#ECECEC"         # Detail viewer window base — windowBackgroundColor, dark #282828
  window-content: "#FFFFFF"        # Detail viewer code wells — controlBackgroundColor, dark #1E1E1E
  status-success: "#28CD41"        # 2xx — Color.green, dark #32D74B
  status-redirect: "#FF9500"       # 3xx — Color.orange, dark #FF9F0A
  status-error: "#FF3B30"          # 4xx / 5xx / transport error — Color.red, dark #FF453A
  status-pending: "#8E8E93"        # in flight, no response — Color(.systemGray)
  separator: "#0000001A"           # separatorColor — dark #FFFFFF1A. Row + section hairlines.
  on-accent: "#FFFFFF"

typography:
  headline:     { style: ".headline",     size: 13, weight: 600, use: "Panel header status, approval-card title" }
  body:         { style: ".body",         size: 13, weight: 400, use: "Default text, card reasons" }
  callout:      { style: ".callout",      size: 12, weight: 400, use: "Feed-row url, metadata, section labels" }
  subheadline:  { style: ".subheadline",  size: 11, weight: 400, use: "Section headers (uppercased): needs you / live" }
  mono:         { style: ".body.monospaced()",         size: 12, weight: 400, use: "URLs, headers, bodies, method glyph" }
  mono-small:   { style: ".callout.monospaced()",      size: 11, weight: 400, use: "Feed-row url + host at panel density" }
  numeric:      { style: ".callout.monospacedDigit()", size: 12, weight: 400, use: "Status codes, durations, port, count" }

rounded:
  sm: 6px          # feed-row / card corners inside the panel
  md: 10px         # approval + fault cards, expanded-row container
  lg: 16px         # Detail viewer code wells
  capsule: 9999px  # ALL buttons, status badges, method chips

spacing:
  xxs: 4px
  xs: 8px
  sm: 12px
  md: 16px         # panel internal padding
  lg: 20px         # Detail viewer content margin

metrics:
  console-width: 300px       # the menu-bar popover (config & control only)
  main-window-default: 1040x640
  sidebar-width: 180-300     # category sidebar (ideal 220)
  main-list-width: 320-520   # request list column (ideal 400)

components:
  # --- Status-bar console (popover) ---
  menu-panel:
    material: "{colors.panel-material}"
    width: "{metrics.console-width}"
    structure: "header (status) · config rows (proxy / system-proxy / rules) · Open Main Window · footer (count · Quit)"
    note: "config & control only — NO request list here"
  config-row:
    anatomy: "SF Symbol (secondary, 20pt) · title ({typography.body}) over subtitle ({typography.callout} .tertiary) · trailing control (Toggle .switch, or status text)"
  approval-card:   # M3, appears above config rows when pending
    backgroundColor: "{colors.attention-fill} @ ~12%"
    rounded: "{rounded.md}"
    anatomy: "tool + target ({typography.mono}) · one-line reason · [Deny] [Approve] [Always]"
  fault-card:      # M2
    backgroundColor: "{colors.status-error} @ ~12%"
    rounded: "{rounded.md}"
    anatomy: "SF Symbol + one-line fault · single fix action"
  # --- Main window (opaque) ---
  main-window:
    structure: "NavigationSplitView: sidebar | VSplitView(request-table top / inspector-panel bottom). Layout follows standard HTTP-debugger conventions (Proxyman/Charles-style). No sidebar/window title."
    defaultSize: "{metrics.main-window-default}"
    toolbar: "centered chip (.principal): status dot + LAN-IP:port (verbatim, no digit grouping) + three gray/green status toggles (System proxy 'globe' · SSL 'lock.shield' · Map/rewrite 'wand.and.stars'). Right (.primaryAction, flat — sharedBackgroundVisibility hidden on macOS 26): Record play/stop ('play.fill'/'stop.fill' + label) + Clear ('xmark.bin'). No search, no title. All icons 16pt with ≥26pt tap targets."
  sidebar:         # left column — categories
    style: ".listStyle(.sidebar)"
    anatomy: "All Flows · Errors · Replayed (each Label + system .badge count) · Section 'Hosts' — one Label per host (globe icon + .badge count). Selection scopes the table."
  request-table:   # top of the split — a multi-column SwiftUI Table
    columns: "status-pill (54) · Method (mono) · Host (mono, secondary) · Path (mono, middle-truncated, + ↻ if replayed) · Time (numeric)"
    selection: "single, drives the inspector below"
  status-pill:     # the table's status column
    typography: "{typography.numeric} semibold"
    rounded: "{rounded.sm}"
    size: "44×20 fixed"
    anatomy: "3-digit code, status-class color 100% text / ~15% fill; ERR on transport error; ProgressView while pending. Method is a separate ink column, never chromatic"
  inspector-panel: # bottom of the split — Request | Response, referenced from Proxyman
    backgroundColor: "{colors.window-canvas}"
    visibility: "shown ONLY when a flow is selected; otherwise the table fills the whole pane"
    structure: "HSplitView — left Request pane, right Response pane, each with its own tab strip"
    requestPane: "tab strip [Summary · Headers(n) · Body · Diff(replays only)] + method badge + Replay button; a copyable URL bar below the tabs. Summary = key/value table (Status/Method/Code/Host/Duration/Started/Origin)."
    responsePane: "tab strip [Headers(n) · Body · Raw] + status badge + ✕ close (deselects). Raw = status line + headers + body with a line-number gutter."
    tabStrip: "text tabs, selected = semibold + 2pt accent underline (custom, not segmented)"
  button-primary:
    style: ".buttonStyle(.borderedProminent)"   # .glassProminent on macOS 26+
    rounded: "{rounded.capsule}"
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
- **Main window** — the *working surface*: a three-column `NavigationSplitView` — category sidebar (All /
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
- **Attention fills**: approval cards tint at ~12% `{colors.accent}`, fault cards at ~12% `{colors.status-error}`
  — just enough to lift them off the feed, still translucent over the material.
- **Main-window surfaces** (opaque, window-only): `{colors.window-canvas}` base, `{colors.window-content}`
  for code wells. These exist *only* in the main window; the console has no opaque surfaces.
- **Status** — the four HTTP voices, the only sanctioned non-accent chromatic color:

  | Class | Token | System color | Applies to |
  |---|---|---|---|
  | 2xx | `{colors.status-success}` | `Color.green` | status badge |
  | 3xx | `{colors.status-redirect}` | `Color.orange` | status badge |
  | 4xx / 5xx / error | `{colors.status-error}` | `Color.red` | status badge; `error` flows; fault cards |
  | in flight | `{colors.status-pending}` | `Color(.systemGray)` | badge shows `ProgressView` |

- **Hairlines** (`separatorColor`): 1px separators between feed rows and stack sections — the panel's only
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
┌─ ● Loom                    Running ─┐   header: status dot + name + state
│ 🌐 Proxy         :9090        [◉]   │   config-row (toggle)
│ 🌍 System proxy  off          [ ]   │   config-row (M2, disabled)
│ ⚙︎ Rules         none yet      Off   │   config-row (M3)
│ ──────────────────────────────────  │
│        [ Open Main Window ]          │   prominent button
│ N flows captured              Quit   │   footer
└──────────────────────────────────────┘
```

(M2 fault cards and M3 approval cards appear between the header and the config rows when present.)

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
- **Toolbar**: a centered chip — status dot + `LAN-IP:port` + three gray/green status toggles (System proxy,
  SSL, Map/rewrite); right-aligned flat buttons `Record` (play/stop) + `Clear` (`xmark.bin`), with the macOS 26
  shared-glass container hidden. No search, no window title. System-proxy/SSL are M2, Map/rewrite and Record
  (interception) are M2/M3 — UI wired now, engines later.
- **Spacing**: base 4pt; console internal padding `{spacing.md}`. If a value isn't a token, it's probably wrong.

## Elevation & Depth

| Level | Treatment | Use |
|---|---|---|
| Console | System vibrant material + automatic popover shadow | the menu-bar surface |
| In-console content | Transparent config rows; ~12% tint for approval/fault cards (M2/M3) | console |
| Window content | Opaque semantic surface, hairlines, system list selection | main window list + detail |
| Overlay | Sheet with system background | cert-setup wizard (M2), confirmations |

Loom never draws a manual `.shadow()` — the only shadow is the system's under the popover/window. In the
console, depth is the material plus tint; do not stack opaque cards on it. Never simulate the material with
`Color.white.opacity(n)` — Reduce Transparency must swap it automatically.

## Shapes

| Token | Value | Use |
|---|---|---|
| `{rounded.sm}` | 6px | status pill, list hover |
| `{rounded.md}` | 10px | approval / fault cards |
| `{rounded.lg}` | 16px | detail-pane code wells |
| `{rounded.capsule}` | ∞ | all buttons |

**Capsule = control, rounded-rect = container.** `RoundedRectangle` is always `.continuous`.

## Components

### Status-bar console

- **`menu-panel`** — the console. Vibrant material, `{metrics.console-width}` wide: header (status) → config
  rows → `Open Main Window` → footer. **No traffic.**
- **`config-row`** — SF Symbol (secondary, 20pt) + title (`{typography.body}`) over subtitle
  (`{typography.callout}` `.tertiary`), trailing control on the right: a `.switch` Toggle (Proxy), a disabled
  Toggle (System proxy, M2), or a status label (Rules, M3).
- **`approval-card`** (M3) — the guardrail's atom, appears above the config rows. ~12% accent fill,
  `{rounded.md}`: tool + target in `{typography.mono}`, a one-line reason, and `[Deny] [Approve] [Always]`.
  Resolves in place.
- **`fault-card`** (M2) — ~12% red fill: SF Symbol + one-line fault + a single fix action. Floats above approvals.

### Main window

- **`main-window`** — `NavigationSplitView`: `sidebar` | `VSplitView(request-table, inspector-panel)`. Opaque,
  no sidebar/window title. Toolbar: `host:port` + status dot centered (`.principal`); `Intercept` toggle and
  `Clear` right-aligned (`.primaryAction`). No search field.
- **`sidebar`** (`.listStyle(.sidebar)`) — `All Flows` / `Errors` / `Replayed` as `Label`s with system
  `.badge` counts, then a `Hosts` section (one `Label` per host, globe + `.badge`). Selection scopes the table.
- **`request-table`** — a SwiftUI `Table` (resizable columns, single selection): status-pill · Method · Host ·
  Path (middle-truncated, `↻` accent glyph if replayed) · Time. Everything from the wire is mono.
- **`status-pill`** — the status column, 44×20 fixed: 3-digit code in `{typography.numeric}` semibold,
  status-class color 100% text / ~15% fill; `ERR` for transport errors; a small `ProgressView` while in flight.
- **`inspector-panel`** — the bottom pane, opaque, shown only when a flow is selected. An `HSplitView` split into
  **Request** (left) and **Response** (right), each with its own text tab strip (selected tab = semibold + 2pt
  accent underline). Left: `Summary · Headers(n) · Body · Diff`(replays) + a method badge, a `Replay` button, and a
  copyable URL bar. Right: `Headers(n) · Body · Raw` + a status badge and a `✕` close (deselects). `Raw` uses a
  line-number gutter. **Replay lives here.** Layout referenced from Proxyman, not copied.
- **`empty-state`** — `ContentUnavailableView`: distinct copy for *proxy stopped* vs *running, nothing captured
  yet*. Never a custom illustration.

## Do's and Don'ts

**Do** — keep config in the console and traffic in the main window; use the vibrant material for the console and
opaque surfaces for the window; route interactivity through `{colors.accent}`; pair every status color with its
numeric code; monospace everything from the wire; use system sidebar `.badge` counts; test light/dark/
increased-contrast/Reduce-Transparency without code branches.

**Don't** — show the request list in the console or config in the window; put opaque white cards on the console
material; hardcode hex/RGB; add a second accent or any gradient; `.shadow()` manually; color the method by
status; fix UI font sizes with `Font.system(size:)`; nest cards; let AI-slop in (emoji in UI copy, an SF Symbol
on every label).

## Iteration Guide

1. Change ONE component at a time; reference its YAML key (`{components.approval-card}`) in commits/reviews.
2. New states of a component are new YAML entries with a `-suffix`, not prose forks.
3. Use `{token.refs}` in specs and a `DesignTokens` enum in code — never inline values.
4. Prefer deleting custom styling over adding it: the target is "system control + tokens + nothing else."

## Known Gaps

- **v2 supersedes the M1 code**: `InspectorView`'s two-column window and the control-only popover both need
  to be rebuilt — panel with live feed + inline expansion, window demoted to `detail-viewer`. Until then the
  running app does not match this spec (the spec wins).
- **Pin/detach** is implemented (`PinController`): the header pin button re-hosts `PanelView` in a
  non-activating floating `NSPanel` (`level = .floating`, `becomesKeyOnlyIfNeeded`) over an
  `NSVisualEffectView(.popover)` so the vibrant material is preserved; the panel's close button unpins.
  Gap: it opens at a fixed 380×560 top-trailing and isn't resizable yet.
- **Approval cards, faults, and scope** are M3 in [`ROADMAP.md`](ROADMAP.md); until then the stack is header +
  feed + footer only. Design them here now so the layout budget accounts for them.
- Liquid Glass button styles (`.glassProminent`/`.glass`) are macOS 26-only; on the macOS 14 baseline use
  `.borderedProminent`/`.bordered`. App icon and brand mark are unspecified; the app carries zero branding until then.
