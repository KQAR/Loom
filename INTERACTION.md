# INTERACTION.md

Single source of truth for Loom's **interaction architecture** — who operates the proxy, how the human supervises from the status bar, and how risky actions are gated. Sits beside [`DESIGN.md`](DESIGN.md) (visual system) and [`ROADMAP.md`](ROADMAP.md) (positioning, iteration order). When a view's structure or flow conflicts with this doc, the view is wrong.

## First Principle: AI operates, the human supervises

Charles and Proxyman put a human at a dense full-window GUI, clicking through flows. Loom inverts the *operator*:

> **The AI agent is the primary operator — it captures, inspects, modifies, and replays traffic over MCP. The human supervises: they watch what the agent did through the audit trail, and can take over at any time.**

The human is *on* the loop, not *in* it. So the human has **two surfaces with sharply separated jobs**: a small **status-bar console** for control and at-a-glance config, and a **main window** for actually reading the request list. The status bar is not a traffic viewer; the main window is not a control panel.

Three consequences shape every decision:

1. **The MCP surface is the real operator surface.** Tool ergonomics (clear names, structured results, honest errors) matter more than pixels. A capability not exposed as a tool doesn't exist for the primary operator.
2. **The status bar is config + control, never traffic.** It answers "is the proxy on? am I the system proxy? which rules are active?" — all at a glance, no scrolling through requests.
3. **The main window is the working surface.** The request list and per-flow detail live there, opened from the console's "Open Main Window" button.

## Two Surfaces, One Job Each

| Surface | Question it answers | Contents |
|---------|--------------------|----------|
| **Status-bar console** (popover) | "What's the current config, and does anything need me?" | proxy on/off · system-proxy state · rules on/off + which · Open Main Window · Quit |
| **Main window** | "What flowed, and what's in this request?" | category sidebar + request list + flow detail (Replay & diff) |

Plus the headless **MCP endpoint** — the operator's surface.

### Status-bar console (config & control)

Click the menu-bar icon → a compact popover (`.menuBarExtraStyle(.window)`; see [`DESIGN.md`](DESIGN.md) `menu-panel`). No traffic here — only state and control:

```
┌─ ● Loom                         Running ─┐
│  🌐  Proxy          127.0.0.1:9090   [◉] │  on/off toggle
│  🌍  System proxy   off · explicit   [ ] │  (M2: needs helper — disabled)
│  ⚙︎  Rules          no rules yet     Off │  (M3: lists active rules here)
│ ───────────────────────────────────────  │
│         [ Open Main Window ]              │
│  5 flows captured                   Quit  │
└───────────────────────────────────────────┘
```

When faults (proxy bind failure, cert not trusted — M2) exist, they appear as cards above the config rows — the console is the single front door for "something needs you". Otherwise it is config + control only.

### Main window (the request list)

Layout follows standard HTTP-debugger conventions (Proxyman/Charles-style): a category **sidebar**, then a vertical split of a **request table** over a **tabbed inspector**.

1. **Sidebar — categories.** `All Flows`, `Errors`, `Replayed` (each with a count badge), then a `Hosts` section grouping traffic by domain. Selection scopes the table.
2. **Request table — the requests.** A multi-column table (status · method · host · path · time), newest first, resizable columns; single selection drives the inspector. `↻` marks agent-replayed rows.
3. **Inspector — the selected flow.** Hidden until a row is selected (the table then fills the whole pane); selecting reveals it below the table, split **Request (left) | Response (right)** — layout referenced from Proxyman. The Request pane has tabs `Summary / Headers / Body` (+ `Diff` for replays), a method badge, a copyable URL bar, and the **Replay** button (same `ProxyEngine.shared` write path the agent uses). The Response pane has tabs `Headers / Body / Raw`, a status badge, and a ✕ close (top-right) that hides the inspector by deselecting.

The window toolbar has a centered status chip — dot + `LAN-IP:port` + three gray/green quick toggles (System proxy, SSL, Map/rewrite) — and, right-aligned, a **Record** stop/play button (capture pause/resume: paused means traffic keeps flowing but isn't stored) and **Clear**. Breakpoint interception is **not** this button; it gets its own gated control in M3. No search field, no window title. Opened from the console; a normal, persistent, resizable window — where the human watches traffic.

## The Guardrail: loopback boundary + full audit trail

The heart of "human stays in control of risk" ([`ROADMAP.md`](ROADMAP.md) value #2). MCP **write** tools (`replay_flow`, `set_rule`, `arm_breakpoint`, …) **act directly — there is no approval gate and no per-host scope allow-list** (owner decision; see [`AGENTS.md`](AGENTS.md)). Control of risk rests on two shipped mechanisms instead.

### 1. Loopback-only control plane (the boundary)

The MCP server binds **loopback only** (`127.0.0.1:9092`), deliberately **not** the proxy's `9090` (which binds `0.0.0.0` when LAN device capture is on). So the write-capable, token-optional control plane is reachable only from this Mac: a device on the Wi-Fi can push traffic *through* the proxy but can never drive Loom's writes. That physical boundary is what keeps writes sanctioned.

### 2. Durable audit trail (accountability)

Every write tool call is recorded in a durable, row-capped audit log (`audit.sqlite`, survives relaunch): tool, arguments, outcome, timestamp. The human reviews it after the fact in the main window's **sidebar → Audit** panel; an agent reads it back via `get_audit_log`. Read tools are never logged, so the trail is exactly the writes — "what did it do?" is always answerable, and each rule hit also lands on the affected flow (`appliedRules`, shown as the wand icon) so a change is traceable to its rule.

## Take-over (manual override)

The human can stop deferring to the agent at any time:

- **Stop the proxy** from the console's Proxy toggle (hard stop; the agent's next tool call fails cleanly with "proxy stopped").
- **Replay by hand** in the main window's detail pane.
- **Disable a rule / disarm a breakpoint** (`set_rules_enabled`, `set_group_enabled`, `disarm_breakpoint`) — immediate, and surfaced back to the agent as a structured result on its next relevant call.

The agent is never a black box the human can't interrupt.

## Degraded & Empty States

- **Faults** (proxy bind failure, upstream unreachable, cert not trusted — M2) render as fault cards at the top of the status-bar console. The agent's affected tool calls return the matching structured error, so human and agent learn of the fault together.
- **Empty list** (main window) has two honest meanings and must not look identical: *proxy stopped* (start it from the console) vs *running, nothing captured yet* (hint: point a client at `127.0.0.1:<port>` / `curl -x`). Use `ContentUnavailableView` for both.

## Menu-bar icon & notifications

- The **menu-bar icon is the ambient channel** and its glyph carries state: dimmed when the proxy is stopped; two-way arrows (`arrow.left.arrow.right`) when running; a branch glyph (`arrow.triangle.branch`) when map/rewrite rules are active. (Its `.task` also boots the capture subscription at launch, so state is live before the popover is ever opened.) Later: tint + count when faults are pending (M2).
- macOS notifications (opt-in, later) surface a **fault** for "away from the machine" — the same fault card, relocated, no new interaction concept.

## Build Order (mapped to ROADMAP)

1. **Done**: status-bar console (proxy on/off · system-proxy + rules status · Open Main Window) and main window (request list + detail with Replay & diff). Config/traffic split is in place.
2. **M2**: real system-proxy toggle (privileged helper); fault cards in the console; cert-setup as a sheet.
3. **M3**: rules + breakpoints + the durable audit trail; write tools act directly (no approval cards or scope allow-list — owner decision); the console's rules rows go live, take-over via stop / disable / disarm.
4. **Parked**: a surface for the human to *drive* the agent from inside Loom (Loom is MCP-first; the agent lives in the user's own client).
