# INTERACTION.md

Single source of truth for Loom's **interaction architecture** — who operates the proxy, how the human supervises from the status bar, and how risky actions are gated. Sits beside [`DESIGN.md`](DESIGN.md) (visual system) and [`ROADMAP.md`](ROADMAP.md) (positioning, iteration order). When a view's structure or flow conflicts with this doc, the view is wrong.

## First Principle: AI operates, the human supervises

Charles and Proxyman put a human at a dense full-window GUI, clicking through flows. Loom inverts the *operator*:

> **The AI agent is the primary operator — it captures, inspects, modifies, and replays traffic over MCP. The human supervises: they watch what the agent did through the audit trail, and can take over at any time.**

The human is *on* the loop, not *in* it. So the human has **two surfaces with sharply separated jobs**: a small **status-bar console** for control and at-a-glance config, and a **main window** for actually reading the request list. The status bar is not a traffic viewer; the main window is not a control panel.

Three consequences shape every decision:

1. **The MCP surface is the real operator surface.** Tool ergonomics (clear names, structured results, honest errors) matter more than pixels. A capability not exposed as a tool doesn't exist for the primary operator.
2. **The status bar is config + control, never traffic.** It answers "is the proxy on? am I the system proxy? which rules are active?" — all at a glance, no scrolling through requests.
3. **The main window is the working surface.** The request list and per-flow detail live there — opened at launch, re-openable from the console's "Open Main Window" row.

## Two Surfaces, One Job Each

| Surface | Question it answers | Contents |
|---------|--------------------|----------|
| **Status-bar console** (popover) | "What's the current config, and does anything need me?" | proxy address + on/off · device onboarding · system-proxy state · HTTPS · client certificates · rules · breakpoints (when armed/held) · Open Main Window · Quit |
| **Main window** | "What flowed, and what's in this request?" | category sidebar + request list + flow detail (Replay & diff) |

Plus the headless **MCP endpoint** — the operator's surface.

### Status-bar console (config & control)

Click the menu-bar icon → a compact popover (`.menuBarExtraStyle(.window)`). No traffic here — only state and control, in three bands: a header (capture dot + proxy address + a Privileged Helper key + the on/off switch), a **switch strip** (System · HTTPS · Rules · Device — tinted glyph over a caption), an **alert channel** that exists only while something is wrong, **config rows** for the things whose state is a phrase (Reverse Proxies · SSL Scope · Client Certificates · Breakpoints — the conditional ones absent rather than empty), and a footer carrying the way into the main window. Which band a control belongs in, and why the alert channel is what makes a three-value tint safe, live in [`DESIGN.md` § Layout](DESIGN.md#layout) (`menu-panel` / `header-glyph` / `switch-tile` / `console-alert` / `config-row`) — one diagram, there, not here.

When faults (proxy bind failure, cert not trusted) exist, they appear as cards above the config rows — the console is the single front door for "something needs you". Otherwise it is config + control only.

### Main window (the request list)

Layout follows standard HTTP-debugger conventions (Proxyman/Charles-style): a category **sidebar**, then a vertical split of a **request table** over a **tabbed inspector**.

1. **Sidebar — categories.** `All Flows` keeps the complete sequence; `Requests` / `Connections` split the two record grains without deleting either, and compose with `Errors`, device and host. `Rules` / `Audit` / `Breakpoints` replace the table. Each row carries a plain trailing count, never a badge pill ([`DESIGN.md`](DESIGN.md) `{components.sidebar-counts}`).
2. **Request table — the raw sequence.** A multi-column table (status · method · host · path · time), newest first, resizable columns; CONNECT diagnostics remain first-class rows. When Connections is selected, a capture-wide strip reports failed vs relayed totals. Single selection drives the inspector; `↻` marks agent-replayed rows.
3. **Inspector — the selected flow.** Hidden until a row is selected (the table then fills the whole pane); selecting reveals it below the table, split **Request (left) | Response (right)** — layout referenced from Proxyman, tab sets per [`DESIGN.md`](DESIGN.md) `{components.inspector-panel}`. What matters here: the **Replay** button lives in the Request pane and runs the same `ProxyEngine.shared` write path the agent uses, and the Response pane's ✕ close hides the inspector by deselecting.

The window toolbar has a centered status chip — dot + the **listener's** `host:port` (the LAN IP while the proxy is bound to `0.0.0.0`, `127.0.0.1` while it is not — an address the listener is not on is worse than a narrow one, because it sends the human to debug their client) + three quick toggles (System proxy, SSL, Map/rewrite) and, behind a divider at the chip's right end, a **Record** start/stop button (capture pause/resume: paused means traffic keeps flowing but isn't stored — it sits in the chip because it is the same capture state the dot reports, and splitting them across the band made two places to look). Nothing is right-aligned: **discarding the capture** is a small floating control over the request list, held rather than clicked to fire, because a destructive action belongs against the thing it destroys and the console's no-dialog rule leaves no room for a confirm sheet (DESIGN.md `{components.clear-fab}`). Breakpoint interception is **not** the Record button — held/armed breakpoints surface in the sidebar → Breakpoints panel and as the console's Breakpoints row. No search field in the toolbar and no window title: filtering is a **find bar**, hidden until ⌘F and revealed directly above the request table, because a find bar belongs against the thing it filters ([DESIGN.md § main-window](DESIGN.md#layout-main-window)). It composes with the sidebar as AND — the category picks *whose* traffic, the needle picks *which exchange* — and deliberately leaves the sidebar counts alone, so "my filter is too narrow" stays distinguishable from "that traffic isn't there". A normal, persistent, resizable window, opened at launch and from the console — where the human watches traffic.

## The Guardrail: loopback boundary + full audit trail

The heart of "human stays in control of risk" ([`ROADMAP.md`](ROADMAP.md) value #2). MCP **write** tools (`replay_flow`, `set_rule`, `arm_breakpoint`, …) **act directly — there is no approval gate and no per-host scope allow-list** (owner decision; see [`AGENTS.md`](AGENTS.md)). Control of risk rests on two shipped mechanisms instead.

### 1. Loopback-only control plane (the boundary)

The MCP server binds **loopback only** (`127.0.0.1:9092`), deliberately **not** the proxy's `9090` (which binds `0.0.0.0` when LAN device capture is on). So the write-capable, token-optional control plane is reachable only from this Mac: a device on the Wi-Fi can push traffic *through* the proxy but can never drive Loom's writes. That physical boundary is what keeps writes sanctioned.

### 2. Durable audit trail (accountability)

Every write tool call is recorded in a durable, row-capped audit log (`audit.sqlite`, survives relaunch): tool, arguments, outcome, timestamp. The human reviews it after the fact in the main window's **sidebar → Audit** panel; an agent reads it back via `get_audit_log`. Read tools are never logged, so the trail is exactly the writes — "what did it do?" is always answerable, and each rule hit also lands on the affected flow (`appliedRules`, shown as the wand icon) so a change is traceable to its rule.

### 3. Supervision that does not lag (the mirror)

The audit trail says what the agent *did*; the console and main window say what the state *is*. Both are supervision, and the second one is the easier to get wrong: a surface holding a copy of engine state has an agent as its other writer, so a write the human is not shown is a write they cannot supervise — indistinguishable, from where they sit, from the write never happening.

So: **every agent write reaches the human's copy of it without the human reopening anything.** The audit stream is the one signal all write tools pass through, so the re-read hangs off it (opt-out, not allowlist — coalesced, so a scripted burst costs one re-read). The writer that is a *human in another app* — CA trust granted in Terminal or revoked in Keychain Access, helper approval in System Settings — is covered by re-reading when Loom comes back to the front. Mechanics and the reasoning: [`AGENTS.md` § Scope](AGENTS.md#scope).

## Take-over (manual override)

The human can stop deferring to the agent at any time:

- **Stop the proxy** from the console's Proxy toggle (hard stop; the agent's next tool call fails cleanly with "proxy stopped").
- **Replay by hand** in the main window's detail pane.
- **Disable a rule / disarm a breakpoint** (`set_rules_enabled`, `set_group_enabled`, `disarm_breakpoint`) — immediate, and surfaced back to the agent as a structured result on its next relevant call.

The agent is never a black box the human can't interrupt.

## Degraded & Empty States

- **Faults** (proxy bind failure, upstream unreachable, cert not trusted) render as fault cards at the top of the status-bar console. The agent's affected tool calls return the matching structured error, so human and agent learn of the fault together.
- **Empty list** (main window) has two honest meanings and must not look identical: *proxy stopped* (start it from the console) vs *running, nothing captured yet* (hint: point a client at the listener's own `host:port` / `curl -x` — the same address the toolbar chip names, never a hardcoded `127.0.0.1`, which is wrong the moment LAN device connection is on). Use `ContentUnavailableView` for both.

## Menu-bar icon & notifications

- The **menu-bar icon is the ambient channel**: it is where the human notices state without opening anything. Which glyph carries which state is DESIGN.md's call — see [`DESIGN.md` § Brand mark](DESIGN.md#brand-mark) (the custom `loom.mark` symbol: hollow node when traffic passes untouched, solid `loom.mark.intercept` when map/rewrite rules act on it, opacity for stopped, color for system-proxy). This doc fixes only the role, not the artwork. (The icon's `.task` also boots the capture subscription at launch, so state is live before the popover is ever opened.)
- macOS notifications (opt-in, later) surface a **fault** for "away from the machine" — the same fault card, relocated, no new interaction concept.

## What's built vs parked

Per-milestone status and the reasoning behind each round live in [`ROADMAP.md`](ROADMAP.md) — not mirrored here. The one deliberately **parked** interaction concept: a surface for the human to *drive* the agent from inside Loom (Loom is MCP-first; the agent lives in the user's own client).
