<!-- CLAUDE.md is a symlink to this file. Always update AGENTS.md, not CLAUDE.md. -->
<!-- Rule: every edit to this file must make it MORE CONCISE or MORE USEFUL. Never add fluff. -->

# AGENTS.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Loom is a personal macOS 14+ app: an **AI-operable debugging proxy** that lives in the status bar. It captures HTTP/HTTPS traffic like Charles/Proxyman, but its primary operator is an AI agent talking **MCP** — and, this is the differentiator, the MCP surface exposes **write actions** (replay, rules, breakpoints), not just read queries. The agent closes the debug loop (capture → modify → replay → diff) with no GUI; the human supervises from the menu bar and gates risky writes.

[`ROADMAP.md`](ROADMAP.md) is the single source of truth for positioning and iteration order. Read it before making scope or prioritization decisions.

**Stack**: SwiftUI + TCA, Tuist, Swift 6 (NIO modules Swift 5), SwiftNIO, SPM, macOS 14+.

## Design System

Three docs govern the product; each wins over code in its domain:

- [`ROADMAP.md`](ROADMAP.md) — positioning and iteration order
- [`DESIGN.md`](DESIGN.md) — visual system for the **status-bar panel** (the whole human surface) + the optional Detail viewer, derived from Apple's HIG, **not** from existing code
- [`INTERACTION.md`](INTERACTION.md) — interaction architecture: the AI-operates / human-supervises inversion, the status-bar panel as the one surface, write-action guardrails

**UI is status-bar-first (DESIGN/INTERACTION v2).** The human surface is a single menu-bar panel (faults → approvals → live feed → control footer); there is no main window. The M1 code still has the old control-only popover + two-column Inspector window — treat that as legacy to rebuild toward the specs, not a pattern to extend.

When a current view conflicts with these specs, the view is wrong: refactor toward the spec, never propagate legacy styling. Read DESIGN.md and INTERACTION.md before writing or reviewing any view code.

## Legal boundary (read once)

Loom is a clean-room implementation. Studying open-source proxies to learn *what* to build and *what interfaces* to expose is fine, but **never copy third-party source into this repo, and never write code by transcribing someone else's** — especially copyleft (AGPL/GPL) projects. Learn MITM/NIO specifics from Apple's swift-nio examples (Apache-2.0) and mitmproxy docs. Ideas and interface shapes are fair game; literal code is not.

## Build Commands

```bash
tuist install                 # Resolve SPM dependencies
tuist generate                # Generate Loom.xcworkspace
tuist build Loom              # Build the app
tuist clean                   # Clean
tuist edit                    # Edit Tuist manifests in Xcode

# Direct xcodebuild (CI / scripted):
xcodebuild -workspace Loom.xcworkspace -scheme Loom -configuration Debug -destination 'platform=macOS' build
xcodebuild -workspace Loom.xcworkspace -scheme loom-mcp -destination 'platform=macOS' build
```

Tuist is pinned to **4.202.5** in `mise.toml` — do not downgrade (see Known Issues).

## Scope

**In scope now (M1 + M2 interception, done)**: HTTP capture proxy, HTTPS MITM interception (on-demand P-256 CA + per-host leaf certs, TLS termination, SSL-proxying scope), in-app MCP server + `loom-mcp` bridge, read tools + write tools (`replay_flow`, `set_ssl_scope`, `export_ca_certificate`), menu-bar shell + Inspector window.
**In scope now also (M3, partial)**: traffic rules — structured `TrafficRule` model (no text DSL; whistle-inspired semantics only) with optional **groups** (batch enable/disable, scenario switching), applied for all paths in one choke point (`RuleApplyingForwarder` decorating `UpstreamForwarding`), persisted in UserDefaults (`com.loom.rules`), exposed as 7 MCP tools + UI (sidebar Rules panel, row context-menu rule templates, rule-hit indicators, `appliedRules` audit on flows). **Owner decision: no approval mode** — all MCP write tools act directly; INTERACTION.md's approval-card gating is not implemented for rules by design.
**Next (ordered — see [`ROADMAP.md`](ROADMAP.md))**: finish M2 (privileged helper for system-trust install + system-proxy — currently an unverified scaffold), rest of M3 (breakpoints, `diff_flows`), M4 protocol breadth (HTTP/2, WebSocket, GraphQL) + persistence.
**Deferred**: Windows/Linux, iOS device capture, team sessions, in-app LLM assistant.

## Core Concepts

### Domain Model (`SharedModels`)

- **Flow**: one captured or replayed request/response exchange. Carries `CapturedRequest`, optional `CapturedResponse`, timing, `error`, and `replayedFrom` (set when produced by a replay).
- **HeaderPair**: headers are an *ordered list*, not a dictionary — order and duplicates are preserved as seen on the wire.
- **ReplayOverrides**: how a flow is mutated before re-send (method / url / set+remove headers / body).
- **ProxyControlling** = `FlowProviding` (read) + `FlowReplaying` (write): the protocol the engine implements and both the TCA client and MCP server consume.

### Runtime Flow

```
Client (curl -x / system proxy)
  └─▶ ProxyCore :9090 ──capture──▶ FlowStore (ring buffer + AsyncStream)
                                        │
                 ┌──────────────────────┴───────────────────────┐
          ProxyClient (TCA)                               MCPServer :<port>/mcp
          drives Inspector UI                             ◀── loom-mcp bridge ◀── AI client
                 └──────── same ProxyEngine.shared, one write path ────────┘
```

Both the UI and the AI act through the **same** `ProxyEngine.shared` — "AI modifies a request" and "human clicks Replay" run identical code. Never fork a second write path.

### The AI link (M1 mechanism)

- `loom-mcp` is a tiny **stdio↔HTTP bridge** with no business logic. Claude Desktop/Cursor launch it; it reads `~/Library/Application Support/com.loom/mcp-handshake.json` (`{token, port}`, mode `0600`) and forwards each JSON-RPC line to `http://127.0.0.1:<port>/mcp` with `Authorization: Bearer <token>`.
- The real MCP server and all tools live in-process in the app, sharing memory with the capture store.

### MCP Tools

| Tool | Kind | Purpose |
|------|------|---------|
| `get_version` | read | app + protocol version |
| `get_proxy_status` | read | running state, port, captured count |
| `get_recent_flows` | read | newest-first flow summaries |
| `get_flow_detail` | read | full headers + body for one flow id |
| `replay_flow` | **write** | re-send a flow with overrides → new flow, linked via `replayedFrom` |
| `get_certificate_status` | read | MITM root-CA state: generated? trusted? fingerprint, expiry, exported path |
| `get_ssl_scope` | read | current interception scope (enabled + include/exclude host globs) |
| `export_ca_certificate` | **write** | write the root CA (PEM) to disk for trusting; returns the path |
| `set_ssl_scope` | **write** | enable/disable HTTPS interception and set include/exclude host globs |
| `list_rules` | read | master switch + all traffic rules (long bodies truncated) |
| `get_rule` | read | one rule by id, full bodies |
| `create_rule` | **write** | structured traffic rule: URL glob/regex + methods → mock / map remote (+exclude/keep-host) / map local / rewrite req+res / find-replace substitutions (request_substitutions/response_substitutions) / block / delay; optional `group` label |
| `update_rule` | **write** | replace fields of a rule by id (per-rule enable/disable, regroup with `group`, `""` ungroups) |
| `delete_rule` | **write** | remove a rule by id |
| `set_rules_enabled` | **write** | master switch for the rule engine |
| `set_group_enabled` | **write** | enable/disable every rule in a group (scenario switching) |

Write tools are the reason Loom exists. When adding one (M3: `create_rule`, breakpoints, `diff_flows`), it must be scoped and — if destructive — gated per [`INTERACTION.md`](INTERACTION.md).

### Key Modules

| Module | Layer | Responsibility |
|--------|-------|----------------|
| **SharedModels** | base | `Flow`, `ReplayOverrides`, `ProxyControlling`, `SSLScope`, `CertificateStatus`, helper XPC protocol + `HelperIdentity`, `ProxyBackup`/`SystemProxyParsing` — no deps |
| **ProxyCore** | engine | SwiftNIO proxy, `ProxyEngine` actor, `FlowStore`, CONNECT tunnel, **MITM** (`CertificateAuthority`, `TLSInterceptHandler`, `CAStore`, `InterceptionConfig`), `UpstreamForwarding` |
| **MCPServer** | engine | loopback JSON-RPC server, tool registry, handshake writer |
| **ProxyClient** | client | `@DependencyClient` wrapping `ProxyEngine.shared` for TCA |
| **PrivilegedHelperClient** | client | app-side TCA surface over the helper: SMAppService register/approve + XPC (system proxy, CA trust) — **unverified scaffold** |
| **AppFeature** | feature | TCA reducer + status-bar panel (live feed) + optional Detail viewer |
| **Loom** | app | MenuBarExtra entry (panel); boots proxy + MCP server |
| **loom-mcp** | tool | stdio↔HTTP bridge binary |
| **LoomHelper** | tool | root daemon: per-service proxy backup/override/restore, CA trust install/verify, caller + Apple-binary validation, crash watchdog, idle-exit — **unverified scaffold** |

## Architecture

### TCA (The Composable Architecture)

- **Reducer**: `@Reducer` macro with `State`, `Action`, `body`.
- **State**: `@ObservableState` struct, `Equatable`; flows held in `IdentifiedArrayOf<Flow>`.
- **View**: SwiftUI with `StoreOf<Feature>`, `@Bindable` store; state→action bindings via `.sending`.
- **Dependencies**: `@DependencyClient` + `DependencyValues` extension. The engine is reached only through `ProxyClient` — reducers never touch NIO.

### Layering (dependency direction is one-way)

```
App → AppFeature → ProxyClient → ProxyCore → SharedModels
                    MCPServer  ─────────────▶ SharedModels
```

Features never depend on each other (M1 keeps a single `AppFeature`; split later). Engine modules never depend on TCA.

### Concurrency

- **App / Features / Clients**: Swift 6 language mode, strict concurrency.
- **ProxyCore + MCPServer**: **Swift 5 language mode** (`SWIFT_VERSION=5.0` in `Project.swift`). SwiftNIO's channel model fights Swift 6 Sendable; handlers are `@unchecked Sendable`. Keep NIO code in these two modules; do not leak channel types across the client boundary.
- `ProxyEngine` and `FlowStore` are **actors**; the shared engine is `ProxyEngine.shared`.
- Replay and proxy forwarding use `URLSession` (M1 pragmatism); replace with streaming NIO client if transparency demands it.

### Conventions

- **Side effects**: always through TCA `Effect` — no async work in views.
- **One write path**: UI and MCP both go through `ProxyEngine.shared`. Adding a write must extend `ProxyControlling`, not bypass it.
- **Bundle prefix**: `com.loom` (personal project — no employer branding anywhere).
- **UI**: follow [`DESIGN.md`](DESIGN.md) — semantic system colors, text styles, capsule controls. Never inline hex or fixed font sizes.

### Project Structure

```
Project.swift                     # Tuist project manifest (all targets)
Tuist.swift                       # Tuist config
Tuist/Package.swift               # SPM dependencies (TCA, swift-nio, swift-nio-ssl, swift-certificates)
Tuist/ProjectDescriptionHelpers/  # Module() target factory
App/Sources/                      # LoomApp (MenuBarExtra + boot)
Features/AppFeature/Sources/      # reducer + MenuBarView + InspectorView
Clients/ProxyClient/Sources/      # TCA dependency over the engine
Clients/PrivilegedHelperClient/Sources/ # app-side surface over the helper (scaffold)
Engine/ProxyCore/Sources/         # NIO proxy, ProxyEngine, FlowStore, MITM (CA, TLS intercept)
Engine/ProxyCore/Tests/           # unit + HTTPS-interception integration tests
Engine/MCPServer/Sources/         # MCP server, tools, handshake
Engine/PrivilegedHelper/Sources/  # LoomHelper root daemon (scaffold); com.loom.helper.plist alongside
SharedModels/Sources/             # Flow, ReplayOverrides, ProxyControlling, SSLScope, CertificateStatus
Bridge/Sources/                   # loom-mcp stdio↔HTTP bridge
```

## Known Issues

- **Tuist ≥ 4.202.5 is required.** TCA 1.26 pulls swift-navigation 2.10, which uses SwiftPM *package traits* (`condition: .when(traits:)`). Tuist 4.176's graph loader ignores traits and drops the `CasePathsMacrosSupport` macro edge → `Unable to find module dependency`. 4.202.5's loader handles it. Pinned in `mise.toml`.
- **NIO modules are Swift 5.** Do not flip `ProxyCore`/`MCPServer` to Swift 6 without reworking the channel handlers off `@unchecked Sendable`. `SystemProxyClient` is also Swift 5 (XPC + continuations).
- **HTTPS leaf certs must use ≤20-octet serials.** `Certificate.SerialNumber()` can yield 21 octets (RFC 5280 violation) which Secure Transport rejects with `-1015 "cannot decode raw data"` — silently breaking interception for ~half of hosts while browsers (lenient BoringSSL) still work. `CertificateAuthority.makeSerialNumber()` clears the top bit; don't revert to the default initializer.
- **The forwarder strips Content-Encoding/Content-Length.** URLSession auto-decompresses upstream bodies, so `URLSessionForwarder` drops those headers (`HTTPUtil.sanitizeDecodedResponseHeaders`) — otherwise the client re-decodes plaintext and fails with -1015.
- **SSL scope persists in UserDefaults** (`com.loom.sslScope`), so HTTPS interception survives relaunch. Without it every launch reset to disabled → all HTTPS blind-tunneled → nothing captured. The test-seam engine passes `InterceptionConfig(defaults: nil)` to stay hermetic.
- **Root CA is stored in a file, not the Keychain.** `FileCAStore` keeps the CA (cert + key) in a 0600 `~/Library/Application Support/com.loom/ca-store.pem` — same as Charles/mitmproxy. This is deliberate: a Keychain item's ACL is bound to the app's code signature, so every ad-hoc rebuild during development re-prompted for the login password on the CA read. A file has no ACL → no prompt. `ProxyEngine.migratedCAStore()` migrates a legacy Keychain CA into the file once (preserving an already-trusted CA); `KeychainCAStore` remains for reference only.
- **HTTPS interception works (M2), but the CA must be trusted manually.** With SSL on and a host in scope, Loom MITM-decrypts and captures HTTPS. Apple domains legitimately fail (cert pinning) — expected, not a bug. A client only trusts the leaf if Loom's root CA is trusted: run `export_ca_certificate`, then `sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain <path>`. The one-click privileged install (`PrivilegedHelperClient` + `LoomHelper`) is a hardened but **unverified scaffold** (caller + Apple-binary validation, per-service proxy backup/restore, crash watchdog, idle-exit). It compiles and its pure logic is unit-tested, but it needs a signed/notarized app with the daemon embedded at `Contents/Library/LaunchDaemons/com.loom.helper.plist` + admin approval, which can't run in CI.
- **CONNECT surgery is order-sensitive.** In `ProxyHandler.interceptTLS` the swap runs on `.end` (after the decoder emits the CONNECT parts); handlers must conform to `RemovableChannelHandler`, the HTTP encoder is removed before TLS writes, and TLS is inserted at the pipeline head. Changing this order reintroduces `WRONG_VERSION`/decode crashes.
- **System-proxy config works without the helper (admin users, silent).** `SystemProxyApplier` runs `networksetup` directly — admin users need no password; non-admin falls back to one osascript admin prompt. State is verified via `SCDynamicStoreCopyProxies`, synced into the UI at boot, and auto-disabled on quit (`AppDelegate.applicationShouldTerminate`). A crash skips the quit cleanup; the boot sync surfaces the stale override on next launch. The XPC helper remains the future option for non-admin, crash-safe installs.
- **Enabling the system proxy also blocks QUIC (`QUICBlocker`).** Browsers default to HTTP/3 over QUIC (UDP 443), which a TCP HTTP proxy can't intercept — so without this, browser page loads bypass Loom entirely (only TCP h1/h2 app traffic is captured). The system-proxy enable script appends a pf rule dropping outbound UDP 443, forcing browsers to TCP fallback; disable/quit restores it. Safety: it copies the user's `/etc/pf.conf` and appends a `com.loom.quic` anchor (never overwrites), records prior pf-enabled state in a marker file, and restore reloads the pristine ruleset. pf needs root, so this rides the same osascript admin call as the proxy — **the live pfctl path is unit-tested + `pfctl -nf` syntax-validated but needs one real toggle to verify end-to-end** (like the other privileged paths). pf is macOS-specific: a named anchor is only evaluated because we append `anchor "com.loom.quic"` to the loaded main ruleset.
