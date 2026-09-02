<!-- CLAUDE.md is a symlink to this file. Always update AGENTS.md, not CLAUDE.md. -->
<!-- Rule: every edit to this file must make it MORE CONCISE or MORE USEFUL. Never add fluff. -->

# AGENTS.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Loom is a personal macOS 15+ app: an **AI-operable debugging proxy** that lives in the status bar. It captures HTTP/HTTPS traffic like Charles/Proxyman, but its primary operator is an AI agent talking **MCP** — and, this is the differentiator, the MCP surface exposes **write actions** (replay, rules, breakpoints), not just read queries. The agent closes the debug loop (capture → modify → replay → diff) with no GUI; the human supervises from the menu bar and gates risky writes.

[`ROADMAP.md`](ROADMAP.md) is the single source of truth for positioning, and the ledger of why each round happened (every phase in it is done; nothing is queued). Read it before making scope or prioritization decisions — [§ Scope](#scope) below is what Loom does *today*, not how it got there.

**Stack**: SwiftUI + TCA, Tuist, Swift 6 language mode everywhere (test bundles included), SwiftNIO, SPM, macOS 15+.

**Fail-open logging, and a fail-open that is *reported***: the engine fails open by design (a corrupt CA regenerates, an unreadable rules file starts empty, a bad SSL scope disables interception, a write that can't reach disk is dropped) — but never silently. Those paths log at error level through `Log` (`proxy`/`tls`/`forward`/`store`/`websocket`/`audit`/`rules`; read them with `log stream --predicate 'subsystem == "com.loom"'`) **and record an `EngineDegradation` in the engine's `DegradationLog`**, which reaches `get_proxy_status.degradations` and the console's alert channel. One entry per kind, counted, cleared by a write that later lands. Adding a new fail-open path means adding both halves — the log line has one reader, and it isn't the operator.

**…and a log line is not enough on its own.** `os_log` has exactly one reader: a human with Console open. Loom's primary operator is an agent, which cannot see it. So a fact the engine holds that decides whether an operator's action was *correct* must also be reachable from a tool — a refused connection is counted in `get_proxy_status.recentRefusals`, a rule write reports `effective` and why not, a TLS failure Loom can attribute says which side rejected whom. Log it for the human, return it for the agent; the 0.0.13 round ([ROADMAP § What the agent can see](ROADMAP.md#what-the-agent-can-see-done-0013)) is four instances of getting only the first half right.

## Design System

Three docs govern the product; each wins over code in its domain:

- [`ROADMAP.md`](ROADMAP.md) — positioning, and why each round happened
- [`DESIGN.md`](DESIGN.md) — visual system for the two human surfaces (status-bar console + main window), derived from Apple's HIG, **not** from existing code
- [`INTERACTION.md`](INTERACTION.md) — interaction architecture: the AI-operates / human-supervises inversion, the console/main-window split, write-action guardrails

**UI is status-bar-first (DESIGN/INTERACTION v3).** The human surface centers on the menu-bar panel — now a compact **config & control console** (`PanelView`): a header (capture dot — green recording · yellow paused · grey off — + proxy address + a Privileged Helper key right after it + the on/off switch), a **switch-tile strip** (System · HTTPS · Rules · Device — a tinted glyph over a caption, where the tint is the state), a **console-alert channel** present only while something is wrong, **config rows** for the controls whose state is a phrase (Reverse Proxies, SSL Scope, Client Certificates, Breakpoints — the last three conditional), and a footer (version · Open Main Window + wordmark · Quit). Which band a control lands in is one question — *can its state be read off a three-value tint?* — and the alert channel is what makes that narrow channel safe: a warning tile with nothing beside it is a dead end, because its own tap turns the broken thing off. The main window (`MainView`) is the working surface — a request table + tabbed inspector — opened at launch. Both are driven by the one `AppFeature` store. Any view that conflicts with the specs is the thing to fix; don't propagate old styling.

When a current view conflicts with these specs, the view is wrong: refactor toward the spec, never propagate legacy styling. Read DESIGN.md and INTERACTION.md before writing or reviewing any view code.

## Legal boundary (read once)

Loom is a clean-room implementation. Studying open-source proxies to learn *what* to build and *what interfaces* to expose is fine, but **never copy third-party source into this repo, and never write code by transcribing someone else's** — especially copyleft (AGPL/GPL) projects. Learn MITM/NIO specifics from Apple's swift-nio examples (Apache-2.0) and mitmproxy docs. Ideas and interface shapes are fair game; literal code is not.

## Build Commands

```bash
tuist install                 # Resolve SPM dependencies
tuist generate                # Generate Loom.xcworkspace
# Build the app (`tuist build` is deprecated; `tuist xcodebuild` wraps xcodebuild).
# The `-workspace` flag is REQUIRED — with only `-scheme` xcodebuild picks the wrong
# project and fails to resolve SPM modules (e.g. "Unable to find module dependency:
# 'ComposableArchitecture'"). Products land in the same DerivedData either way.
tuist xcodebuild -workspace Loom.xcworkspace -scheme Loom -configuration Debug -destination 'platform=macOS' build
tuist clean                   # Clean
tuist edit                    # Edit Tuist manifests in Xcode

# Direct xcodebuild (CI / scripted):
xcodebuild -workspace Loom.xcworkspace -scheme Loom -configuration Debug -destination 'platform=macOS' build
xcodebuild -workspace Loom.xcworkspace -scheme loom-mcp -destination 'platform=macOS' build

# Consume the engine as a plain SPM library (no Tuist / Xcode needed):
swift build                   # builds LoomSharedModels + LoomProxyCore from the root Package.swift

# Run every test bundle exactly the way CI does (all 5 targets, one scheme):
tuist generate --no-open      # REQUIRED first — see the false-green note below
xcodebuild test -workspace Loom.xcworkspace -scheme Loom-Workspace -destination 'platform=macOS' \
  -resultBundlePath /tmp/Tests.xcresult
scripts/assert-tests-ran.sh /tmp/Tests.xcresult ProxyCoreTests AppFeatureTests MCPServerTests \
  PrivilegedHelperClientTests SharedModelsTests
```

Tuist is pinned to **4.202.8** in `mise.toml` — 4.202.5 is the floor, do not downgrade (see Known Issues).

**Never trust `** TEST SUCCEEDED **` on its own.** `Project.swift` lists sources by glob, and the
glob is expanded at *generate* time into the `.xcodeproj` — so a test file added since the last
`tuist generate` isn't in the target, and xcodebuild reports success having run **zero tests**. Same
if a bundle drops out of the scheme's test action. `scripts/assert-tests-ran.sh` is the actual pass
condition: it reads the result bundle and fails unless every named bundle ran and nothing failed.

## CI

`.github/workflows/ci.yml` gates every PR and every push to main:

| Job | What it protects |
|-----|------------------|
| **Build & test** | The whole Tuist graph compiles; all five test bundles run (`Loom-Workspace` scheme) and pass, verified through `assert-tests-ran.sh`. |
| **SPM library** | `swift build` + `swift test` on the root `Package.swift` — the embeddable `LoomProxyCore`/`LoomSharedModels` graph resolves without Tuist (this is what Reticle consumes, and it can rot silently otherwise). |
| **Thread Sanitizer** | `ProxyCoreTests` under TSan — the only check on the `@unchecked Sendable` channel handlers, which the Swift 6 language mode does not verify. Baseline is clean (464 tests in 78 suites, zero races). A run that didn't complete is treated as inconclusive-and-failing rather than "no races found", because the two are indistinguishable from an exit status. `scripts/tsan-local.sh` exists for a local run and **currently fails to load the test bundle on this machine**, which is a bundle-load failure rather than a signal — the mechanism, and what the "it can never run locally" claim got wrong, are in [`Engine/ProxyCore/CLAUDE.md` § Known issues (engine-scoped)](Engine/ProxyCore/CLAUDE.md#known-issues-engine-scoped). |
| **Documentation gates** | `verify-doc-budgets.py` + `verify-md-links.py` (below). The **only** job that is not skipped on a docs-only change, which is the point: both protect prose, and a docs-only change is made of it. |

**CI caches dependency *sources*, never build products, and that is load-bearing.** `actions/cache` used to carry `${{ runner.temp }}/DerivedData` keyed on `Tuist/Package.resolved` with a bare prefix restore-key — so any branch restored any other branch's compiled products, while the generated Xcode projects also depend on `Tuist/Package.swift` (its `productTypes` decide whether each vendored C target is a dynamic or static framework), which the key never covered. A DerivedData built under one build graph and reused under another fails in ways that read exactly like source bugs: it produced `error: Cycle inside CNIOFreeBSD … 'Copy Module Map'` on ~75 % of runs during the Swift 6 migration (6 of 8) that **no local build could reproduce**, and then, once the graph changed underneath the stale products, `fatal error: module map file … not found`. Two dead ends before the cause was found, both recorded here so they aren't re-walked: it is not the "just re-run it" flakiness below (a solo re-run failed three times while a *different* job on the same commit passed), and it is not eager linking (`EAGER_LINKING = NO` changed nothing, despite the cycle trace being rooted at `EagerLinkingTBDs/…`). Checkouts stay cached — re-downloading them is what actually cost time, and `Package.resolved` is a sound key for source. Every run now compiles from scratch, which is slower and correct.

`.github/workflows/release.yml` is separate and tag-driven (see Release & Auto-Update).

### Documentation budgets, and links that are checked

**This file loads in full at the start of every session, so its size is paid per *task*, not per
read.** Three gates hold that line, all in CI's `docs` job — the only job a docs-only change does
not skip — and in `.githooks/pre-commit` for the files they read:
`scripts/verify-doc-budgets.py` (word ceilings from `scripts/doc-budgets.json`, a **ratchet, not a
reduction target**: relocate → condense → raise, and a raise is justified in the PR),
`scripts/verify-md-links.py` (every relative link and every `#fragment`, so **a relative Markdown
link is the checked form of a cross-reference and naming a section in prose is not**), and
`scripts/verify-decision-records.py` (every decision record indexed and linked both ways, every
module `CLAUDE.md` budgeted and reachable from here).

**There is deliberately no target word count**, because any number worth holding to would have to
be derived and none was. What belongs where is decided by one question — *would an agent doing an
unrelated task be wrong without this?* — with only-while-touching-this-module going to that
module's `CLAUDE.md`, only-while-doing-this-task to a skill, and history to `docs/decisions/`.
The full standard, the carve-outs, and what relocating gets wrong:
[`.claude/skills/docs-standard`](.claude/skills/docs-standard/SKILL.md).
## Scope

What Loom does today, and the invariants each capability carries. **Which round built what, and why that round happened at all, is [`ROADMAP.md`](ROADMAP.md)** — mirroring its milestone ledger here is what made this section a second changelog.

**Capture and interception**: HTTP capture proxy, HTTPS MITM interception (on-demand P-256 CA + per-host leaf certs, TLS termination, SSL-proxying scope), in-app MCP server + `loom-mcp` bridge, read tools + write tools (`replay_flow`, `set_ssl_scope`, `export_ca_certificate`), menu-bar shell + Inspector window.
**The listen port has one write path, and a status that explains itself**: `ProxyControlling.setListenPort` is the only way the port moves — the toolbar's address editor and `set_proxy_port` both land on it, sharing `ListenPortRules` (SharedModels) for validation. `ProxyStatus` answers "why" as well as "what" (`listenerError`, `socksError`, `degradations`), because `isRunning: false` and `lanReachable: false` each have two causes and an agent otherwise cannot tell a setting from a failure. What a move must carry, and the wildcard-versus-loopback trap where a successful bind loses every local client: [`Engine/ProxyCore/CLAUDE.md`](Engine/ProxyCore/CLAUDE.md#moving-the-listener).

**Rules, diff and breakpoints**: traffic rules — structured `TrafficRule` model (no text DSL; whistle-inspired semantics only), optional **groups** (scenario switching), applied for all paths at one choke point (`RuleApplyingForwarder` decorating `UpstreamForwarding`), persisted in UserDefaults (`com.loom.rules`), exposed as 7 MCP tools + the sidebar Rules panel. Plus **`diff_flows`** (closing the capture→modify→replay→diff loop) and **breakpoints** — `BreakpointForwarder` (outermost `UpstreamForwarding` decorator) + a lock-based `BreakpointStore` park a matching exchange on a continuation; surfaced via `list_pending` / `wait_for_pending` (blocking, fed by `pendingStream()`), released with `resume` (edit or abort). **Not persisted** (a held exchange holds a live connection). **Owner decision: no approval mode** — all MCP write tools act directly; supervision is the loopback boundary + audit trail ([INTERACTION.md § Guardrail](INTERACTION.md#the-guardrail-loopback-boundary--full-audit-trail)).
**Cheaper agent loops**: content search (`header_contains`/`body_contains`), blocking waits (`wait_for_flow`/`wait_for_pending`) instead of poll loops, aggregation (`get_stats`), batch replay (`replay_flow(count:concurrency:)`), origin-scoped rules/breakpoints (`RuleMatch.sourceApp`/`deviceIP`, threaded via `forwardStream(…, origin:)`, fail-closed on unattributed traffic), routing visibility + control (`get_proxy_status.systemProxy`, `set_system_proxy` through the app-injected `SystemRoutingControlling`; plus `refusedConnections`/`recentRefusals` from a bounded `RefusalLog`, because a connection Loom accepted and turned away — a SOCKS4 client, an HTTP request on the SOCKS port — used to reach only `os_log` and so looked identical to a client that never ran), and HAR both ways (`import_har`, `export_har(redact:)`).
**Capture reach — a SOCKS5 listener and mutual TLS**: a **SOCKS5 listener** (`SOCKSServer` + `SOCKSConnectionHandler`, one port above the HTTP proxy, reported as `get_proxy_status.socksPort`) for clients the HTTP port can never see (`ALL_PROXY`-only tools, SOCKS-only proxy fields, non-HTTP protocols), and **mutual TLS** (`ClientCertificate` in `ClientCertificateConfig`, PKCS#12 + passphrase, host-glob scoped; three MCP tools and a conditional console row). Capture strategy is decided by **sniffing the first bytes** (`ProtocolSniff`), never from the port number — `CONNECT` included, which took a bug to get right. The preface `PRI * HTTP/2.0` is its own verdict (`.h2c`, 0.0.27) and gets `MITMPipeline.installCleartextHTTP2` — the *same* stack the ALPN `h2` branch installs, differing only in the scheme it records. It was `.opaque` until then, on the reasoning that h2 needs a negotiated ALPN; ALPN only *says* h2, and prior knowledge (RFC 9113 §3.4) says it more directly. What that reasoning cost is the failure `TunneledHostLog` exists to prevent, on the one protocol where it was still live: gRPC over cleartext, Go's `h2c.NewHandler` and any internal HTTP/2 endpoint reached without TLS recorded **no flow at all**. Four invariants:
  - **The 150 ms sniff deadline (`TunnelSniffHandler.sniffDeadline`) schedules a question; it does not answer one.** SSH/SMTP/IMAP/MySQL/PostgreSQL are *server-first*, so classifying on client bytes alone deadlocks them — that is why a timer exists. It used to *conclude* on expiry (`.opaque`, relay unread), and that was wrong for every case it could reach: `ProtocolSniff.classify` already decides `.opaque` on the first byte of anything it doesn't recognise, so the only state that survives to the deadline is silence or an unfinished prefix, and neither is evidence. Expiry now opens a **speculative upstream connection** and lets whichever side speaks next settle it. Silence from both is not a verdict — the tunnel stays undecided, which is what it is. The two defects this closes were measured, not theorised (a pooled client that pre-connects and speaks seconds later; a ClientHello split across the deadline on a lossy link), and both were invisible in the worst way: the app worked, and Loom recorded nothing.
  - **Both entry points install the same stack through `MITMPipeline`.** The intercepted handler names are load-bearing for the WebSocket upgrade, and two copies is how one entry point rots — which is also why `TunnelSniffHandler` is one handler owning classification for both.
  - **A configured-but-unloadable client identity throws** rather than connecting without it, the bundle is validated **when set** (a wrong passphrase fails there, not hours later), and the audit trail redacts `pkcs12_base64` / `passphrase`.
  - **A refused upstream handshake is wrapped in `UpstreamTLSError`** — naming the host and which identity Loom presented, or none — and lands in `Flow.error`. It must sit in `StreamingResponseHandler` (TCP connect succeeds; the handshake fails later inside the pipeline) and it states what Loom *did*, never what the server wanted — only NIOSSL's own errors are wrapped, `ForwarderError.connectionClosed` deliberately not. One `NIOSSLContext` is cached per identity and **dropped on mutation**, or an edited identity keeps presenting the old one.

  Does **not** cover a process that ignores every proxy setting (transparent/pf redirection — deliberately not planned). Why the sniff replaced port-based classification, the browser `ws://` case that forced it, and the SSH verification story: [ROADMAP § M8](ROADMAP.md#m8).
**Reverse-proxy endpoints**: a local port that stands in for one upstream origin (`ReverseProxyServer` + `ReverseProxyConfig`, persisted in `reverse-proxies.json`; three MCP tools; `ProxyClient` endpoints + `ProxyCapability` cases; `get_proxy_status.reverseProxies`; the console's **Reverse Proxies** row + `ReverseProxyCard`, which is the **only** human-facing rendering of them, agent-created ones included). The escape hatch for a client that **cannot be pointed at a proxy at all** — the measured case is Node's global `fetch`/undici, which ignores `HTTP_PROXY` outright. Four rules, each pinned by a test:
  - The inbound hop is **plain HTTP even when the upstream is https**, so no `NODE_EXTRA_CA_CERTS` and no keychain step. An HTTPS *inbound* endpoint is deliberately not offered, because it would put that step back.
  - The captured flow records the **upstream** URL, never `127.0.0.1:port` — otherwise every rule an agent wrote against the real host would silently stop matching.
  - `create` **binds before it persists** and throws when it can't listen; boot binds **fail open per endpoint** with the reason in `ReverseProxyStatus.error`. A create has a caller waiting, a relaunch does not.
  - It is a **mode on `ProxyHandler`**, not a second handler, so body streaming, capture, rules, breakpoints and the WebSocket splice cannot diverge between entry points (same reasoning as `MITMPipeline`).

  Endpoints persist across relaunch because their port lives in a dev server's config file that Loom restarting doesn't edit. Why the console owns creation and why there is exactly one rendering: [ROADMAP § Reverse-proxy endpoints](ROADMAP.md#reverse-proxy-endpoints-done-0015).

**A privileged helper, so the system-proxy toggle stops asking for a password**: a root LaunchDaemon (`loom-helper`) registered through `SMAppService`, approved once in Login Items, reached over XPC. It exists because enabling the system proxy also blocks QUIC through pf, and `/dev/pf` is root-only even for an admin — which made *every* enable cost a prompt. Surfaced as a **Privileged Helper** key glyph on the console's address line, plus a `console-alert` line for the two states the human must act on (its three states need three verbs — install / go approve / remove — which neither a switch nor a bare glyph can say) and to an agent as `get_proxy_status.privilegedHelper` + `systemProxyChangePrompts`, because `set_system_proxy` blocking on a modal only a human can dismiss otherwise looks like a hang. Three constraints:
  - The XPC interface takes **parameters, never a script**, and not the host either — the daemon hardcodes `127.0.0.1`, so this surface cannot redirect the machine's traffic.
  - The helper is **never load-bearing**: `SystemProxyApplier` falls through to `networksetup` + osascript when it is absent, unapproved, or silent.
  - Under an ad-hoc signature the caller check degrades to `identifier "com.loom.app"`, which **any local process can forge** — so the helper only does what an admin account could already do silently, or whose worst case is a reversible local DoS. **CA trust is deliberately not on it** (forgeable caller + root CA installation is machine-wide MITM); that stays the user-domain button and the manual `sudo`.

  The measurement that overturned "an ad-hoc daemon can never load", and what the 0.0.16 deletion got wrong: [ROADMAP § M2](ROADMAP.md#m2) and [`docs/decisions/privileged-helper.md`](docs/decisions/privileged-helper.md).

**A whitelist SSL scope, and a pass-through that is never silent**: the scope is a **whitelist** — `include` starts empty and nothing is decrypted until a host is named. The wide default it replaces (`include: ["*"]`) made Loom terminate TLS for every client on the machine and had to be undone host by host before an app under test would run; [`docs/decisions/ssl-scope-whitelist.md`](docs/decisions/ssl-scope-whitelist.md) has the comparison and what each direction costs. What ships alongside it is `TunneledHostLog`: every relayed origin recorded with a `TunnelReason`, because an unread relay records **no flow at all** and so reads identically to a client that never ran — which is exactly the state a `set_ssl_scope` carve-out puts a host into. Human surface: the console's **SSL Scope** row + `SSLScopeCard`. Agent surface: `get_ssl_scope.tunneledHosts` (one call — an agent that has to ask twice concludes "no requests" first) + the `intercept_host` write tool, which reports `effective`, because an include entry cannot beat a wildcard `exclude`. Both rationales and the mechanics are in [§ Known Issues](#known-issues) — "The scope is a whitelist".

**Next — nothing is queued, and that is deliberate.** There is no checklist to work down: **pick the next round from real usage pain**, not from a leftover list. What was decided-rather-than-built, and what stays parked (system-domain CA trust, which needs a caller check an ad-hoc signature can't give), is in [ROADMAP § M7](ROADMAP.md#m7) and [§ M2](ROADMAP.md#m2). Breakpoint supervision is **closed**: `BreakpointsFeature` mirrors armed + held state (boot seed → `pendingBreakpointStream` → re-sync after every write, plus a slow poll only while something is held — a hold can also resolve with no decision, on client hangup or the watchdog), surfaced in the **sidebar → Breakpoints** panel and a conditional orange console row. Editing a held exchange stays agent-only (`resume` over MCP); the human's two decisions are proceed-unmodified and abort — deliberately no second write path onto the same continuation.

**Parity of the two control surfaces is now an invariant, not a habit.** `ProxyCapability` (next to `ProxyControlling` in SharedModels) enumerates every requirement of the engine's control surface, and `ProxyClientParityTests` switches over it exhaustively: adding a protocol requirement means adding a case, which fails to compile until it is either wired to a `ProxyClient` endpoint or recorded as `.deliberatelyAbsent("reason")`. The MCP side needs no such guard (it reaches the protocol directly, so the compiler keeps it complete); the hand-written TCA mirror is the side that drifted, which is how the breakpoint gap opened in the first place.

**The sidebar's Devices and Apps are one tree, and its selection is a set.** Two changes with one cause — a flat Apps section could only list *local* apps (see `SourceApp` above), so a phone's traffic was one undifferentiated bucket and the same flow sat in two unrelated groupings with no way to ask "this app, on this device". Now an app row is a child of the device it ran on, and `FlowCategory.app(device:key:)` carries both halves. Four rules, three of which were a wrong first attempt:
  - **The joint count is its own aggregate** (`FlowAggregates.deviceAppCounts`, and a fourth `GROUP BY` in `FlowPersistence.aggregate`). An app's total and a device's total overlap, and no arithmetic over them recovers how many of Safari's flows were the phone's.
  - **The fold control is a chevron inside the device row, not a `DisclosureGroup`.** A `DisclosureGroup`'s label is not a selectable `List` row, so the device would stop being clickable — and selecting a whole device is the more common of the two things the tree is for. The persisted set is the **collapsed** one, so a device Loom has never seen arrives expanded.
  - **A set selection means OR within a dimension and AND across** (`FlowCategory.Dimension`): two hosts is either host, a host plus a device is that host's traffic from that device. Devices/apps share the origin dimension; Requests/Connections share record kind, so both selected means the raw sequence. Panels and `.all` are exclusive, an empty selection is `.all`, and `FlowCategory.normalizeSelection` is the one place that knows it.
  - **`FlowSearch.engineQuery` may under-narrow but never over-narrow.** `FlowQuery` holds one value per field, so a three-host selection cannot be pushed down — and sending one of them would drop the other two's matches while reporting the answer as complete. It pushes a dimension only when that dimension has exactly one member; the window's own predicate applies the rest, and the cost is a few extra body hydrations.

**A human surface that mirrors engine state re-reads it; it does not hold a copy and hope.** Parity of *capability* (above) is not parity of *value* — the TCA state can name every endpoint and still show a stale answer, because the engine's other writer is an agent. Three rules, each of which was a bug first:
  - **A fact the engine owns is a projection of `status`, never a second stored property.** `isRecording` was a local flag defaulting to `true` that nothing ever reconciled, so `set_recording(false)` stopped capture while the dot stayed green and the button still offered "Stop" — and no surface could be reopened to fix it, because none read the engine's value anywhere. Note the direction: `get_proxy_status` was right for the agent the whole time. **The "log it for the human, return it for the agent" rule at the top of this file cuts both ways**, and this is the half that is easier to miss, because the agent-facing gap is the one that gets noticed.
  - **The re-read hangs off the audit stream, as an opt-out.** Every write tool passes through `MCPToolExecutor.call` and lands in the trail, so `AuditFeature` is the one place that learns of all of them; the parent fans out to `status` + rules + interception. It was an **allowlist** of two tools out of twenty (reverse proxies only) and that is exactly what rotted — inverted, the cost of forgetting a new tool is a redundant in-memory read rather than a surface that quietly disagrees. `liveStreamedTools` is the opt-out and every entry needs a live stream to point at. The fan-out is **coalesced on a 200 ms trailing window**, not filtered per tool: `status()` hops onto `FlowStore`, which every capture write queues on, so a scripted burst of fifty rule writes must cost one re-read — and deciding *which* tools deserve one is the allowlist again.
  - **The other writer is not always an agent, and activation is what covers that one.** CA trust is set by the human running Loom's printed `sudo security add-trusted-cert`, or revoked in Keychain Access; helper approval happens in System Settings. None is a write tool, and the main window's `.task` fires **once per launch** — there is no scenePhase or focus refresh in the tree, which is why the panel (re-read on every open) hid this for so long. `AppActivation.events()` treats coming back to Loom as `.viewAppeared`. A `com.apple.security.trustsettingschanged` Darwin notification is deliberately **not** used: the constant is not in the public SDK, the framework binary is in the dyld shared cache so the name cannot be confirmed by inspection, and proving Security.framework posts it needs a real trust change behind an authorization prompt — an unverifiable dependency whose failure mode (a watcher that never fires) is indistinguishable from having nothing to report.

**Deferred**: Windows/Linux, iOS device capture, team sessions, in-app LLM assistant.

## Core Concepts

### Domain Model (`SharedModels`)

- **Flow**: one captured or replayed request/response exchange. Carries `CapturedRequest`, optional `CapturedResponse`, timing (`startedAt` → `firstByteAt` → `completedAt`, giving `ttfbMS` = server think-time and `receiveMS` = body transfer, so "why is this slow" is answerable; HAR maps them to `timings.wait`/`receive`, with `-1` for phases Loom doesn't measure), `error`, `replayedFrom` (set when produced by a replay), `sourceApp` (the originating app: a local process resolved via one cached libproc `localPort→pid` sweep per burst — loopback peers only, since a LAN device has no local pid and its remote port could collide with a local socket's — or, for a LAN device, the app named in its `User-Agent`; see **SourceApp** below, which is where the two are kept apart) and `sourceDevice` (originating device: this Mac or a LAN device, keyed on remote IP, typed from User-Agent via `UserAgentParser`).
- **HeaderPair**: headers are an *ordered list*, not a dictionary — order and duplicates are preserved as seen on the wire.
- **SourceApp** carries **how** it was attributed, and that is a stored field rather than something read off a nil `pid`. A local process comes from libproc via the connection's source port — exact, with a bundle id and an icon. A LAN device has no local pid, so the only evidence is what the app says about itself in `User-Agent`, and `SourceApp.attribution` (`.process` / `.userAgent`) is what keeps a claim from reading as a measurement. Three rules:
  - **`UserAgentParser.app` answers "which app", which is a different question from `client`.** `client` types the *device* and is happy to say `Android app` for a Dalvik UA; as an app bucket that would file every app on the phone together. So an HTTP stack (`okhttp`, `Dalvik`, `CFNetwork`, `python-requests`, …) yields **nil**, a browser yields the browser, and everything else yields the leading product token. Matched against the whole token, never as a substring — `OkHttpDemo` is an app.
  - **Only LAN peers get it.** A loopback request has a pid, and falling back to the header when the resolver comes up empty would mix a fact and a claim on the one surface where the exact answer is available. It is also free: the header is already parsed, so unlike the libproc sweep it costs no latency and needs no backfill.
  - **It flows into origin-scoped rules and breakpoints**, because "which app" is the same question there — a rule scoped to a phone's app now matches, where before every LAN request was unattributed and failed closed.
- **FlowTransport**: how an exchange *travelled*, as opposed to what it said — upstream `remoteAddress`, `connectionReused`, both TLS legs (`clientTLSVersion` and `upstreamTLS`, two independent handshakes that routinely disagree), and the response's `responseContentEncoding` / `responseEncodedBodyBytes`. Four rules, each of which was a gap first:
  - **The client's HTTP version is `CapturedRequest.httpVersion`, a different field from `CapturedResponse.httpVersion` on purpose.** The response's is Loom's *upstream* hop, which since 0.0.27 **matches the client's protocol** rather than always being HTTP/1.1 (see [§ "The upstream leg matches the client's protocol"](Engine/ProxyCore/CLAUDE.md#the-upstream-leg-matches-the-clients-protocol-0027)) — the two still routinely disagree, because an origin may decline `h2` and because a client certificate, a `mapRemote` to an h1 origin or an h1 client all keep the upstream leg on HTTP/1.1. Before that, the forwarder always spoke HTTP/1.1 — so an intercepted h2 request read as HTTP/1.1 on every surface Loom had, and the request table's Protocol column deliberately showed the *scheme* instead, because the only version available to it would have been a lie. It is **stated by the entry point, never derived from the head**: `HTTP2FramePayloadToHTTP1ServerCodec` hands `TLSInterceptHandler` an HTTP/1.1 head, so deriving records the shape of the conversion rather than what the client negotiated. `MITMPipeline` passes the ALPN result down (`CapturedExchange.ClientLeg`) and reads the client TLS version there too — on an h2 stream channel the `NIOSSLServerHandler` is on the *parent*, so a per-request read answers nil.
  - **Absent means unmeasured, never "no".** No transport at all is an exchange that never reached a socket (mocked, blocked, still pending); an absent `upstreamTLS` is not a plaintext hop. The renders omit the key and the Inspector omits the row, rather than either saying "none".
  - **It arrives in two instalments and is *merged*, never replaced** (`FlowTransport.merging`). Everything the connection knows rides the response head; the encoded body size is only a number once the body has finished, so it comes with the end. `FlowStore.upsert` also preserves a landed transport against a late head-parsed pending record — the same unordered-Task race `sourceApp` is already guarded against.
  - **The setup phases belong to the exchange that opened the connection, and to no other.** `ConnectionSetup` (`dnsMS` / `tcpMS` / `tlsHandshakeMS`) is the half of "why is this slow" TTFB folds into the server's think-time — measured live, a first request to `example.com` was 279 ms of which 184 ms was setup, and the next one over the same socket was 169 ms with none. A reuse paid none of it, so it reports none of it; `connectionReused == true` and an absent `setup` are one statement from two sides. Three measurement rules: **DNS is timed by resolving once for measurement and then letting the bootstrap connect normally** — handing the resolved address to `connect(to:)` would drop NIO's Happy Eyeballs across the A/AAAA answers, i.e. change how Loom behaves on every dual-stack network to make a number prettier, and the duplicate lookup is the cached one; **`tcpMS` excludes the handshake** (HAR nests `ssl` inside `connect`, the model keeps them disjoint and `HARExport` adds them back at the format boundary, because two overlapping numbers on one surface need explaining); and **`requestSendMS` is refused on the exchange that opened a TLS connection**, because NIOSSL buffers writes until the handshake completes — measured, that clock came back digit-for-digit equal to `tlsHandshakeMS`, a wrong answer dressed as a precise one.
  - **The encoded size is counted upstream of the decompressor** (`UpstreamEncodedBodyCounter`, between `addHTTPClientHandlers()` and `NIOHTTPResponseDecompressor`), because that is the only place it still exists: the forwarder inflates the body and then strips `Content-Encoding`/`Content-Length`, and the latter would not have answered anyway — a chunked response carries none. The negotiated **cipher suite is deliberately absent**: NIOSSL exposes the version and the peer certificate off a live connection and nothing else, so a cipher field could only be reconstructed from the *configured* suite list, and a field that is right most of the time is worse than no field on a surface used to judge whether a handshake behaved.
- **ReplayOverrides**: how a flow is mutated before re-send (method / url / set+remove headers / body).
- **ProxyControlling** = `FlowProviding` (read) + `FlowReplaying` (write) + TLS / capture / rules / breakpoints / audit: the protocol the engine implements and both the TCA client and MCP server consume. `ProxyCapability` enumerates its requirements so the hand-written TCA mirror can be checked against it (see the parity note in Scope).
- **FlowComparison**: what changed between two flows (scalars, header add/remove/change with repeats preserved, LCS line diff, binary/oversize fallbacks, "one side never answered", WebSocket frame logs). **One** definition, rendered two ways — as JSON by `diff_flows`, as rows by the Inspector's diff pane. They used to disagree, which meant the agent and the human supervising it were reading different answers to the same question. A new rule about what counts as a difference goes here, never in a renderer. Three rules it now holds, each of which was a wrong answer first: a **capped body is not a comparison** (`isPartial` qualifies every "identical" — see [ProxyCore/CLAUDE.md § "A capped capture is never silent"](Engine/ProxyCore/CLAUDE.md#a-capped-capture-is-never-silent)); the line diff is bounded in **bytes** as well as lines (`maxDiffLineBytes` / `maxDiffBytes`, because minified JSON is one line and sails straight past a 400-line cap); and **timing is deliberately not a difference** (two runs never share it, so diffing it would make `isIdentical` always false and so useless), as an absent body is not a difference from an empty one.

### Runtime Flow

```
Client (curl -x / system proxy)   ──▶ ProxyCore HTTP  :9090 ──┐
Client (ALL_PROXY / SOCKS field)  ──▶ ProxyCore SOCKS5 :9091 ──┴─capture─▶ FlowStore (ring + AsyncStream)
                                        │
                 ┌──────────────────────┴───────────────────────┐
          ProxyClient (TCA)                               MCPServer :<port>/mcp
          drives Inspector UI                             ◀── loom-mcp bridge ◀── AI client
                 └──────── same ProxyEngine.shared, one write path ────────┘
```

Both the UI and the AI act through the **same** `ProxyEngine.shared` — "AI modifies a request" and "human clicks Replay" run identical code. Never fork a second write path.

### The AI link

Two ways in, both hitting the **same** in-process MCP server (all tools + state live in the app, sharing memory with the capture store):

- **HTTP direct (Claude Code / Cursor plugin)** — the app serves MCP over HTTP on a **fixed loopback port `127.0.0.1:9092`** (`MCPServer.defaultPort`). The `loom` plugin's root `.mcp.json` points a `type: http` server at `http://127.0.0.1:9092/mcp`; Claude/Cursor just connect — they do **not** launch or build anything, so a random-port bridge is unnecessary. Loopback requests need **no token** (`authorized()` allows a missing `Authorization` header on the loopback-only endpoint); a token, when sent, must still match. **Local trust is why a browser must be kept off this endpoint**, and two checks in `MCPHTTPHandler` do it: a request carrying an `Origin` header is `403`d (no real client is a web page), and a request whose Content-Type isn't `application/json` is `415`d — the latter is load-bearing, because `application/json` is not CORS-safelisted, so a cross-site `fetch` has to pass a preflight this endpoint fails. Without them any site could POST `text/plain` at 127.0.0.1:9092 with no preflight and fire write tools; the response is unreadable cross-origin, but the write already happened. The app owning the server means: if the tools are unreachable, the app isn't running — the skill tells the agent to install/launch Loom rather than fabricate data.
- **stdio bridge (Claude Desktop / other stdio-only clients)** — `loom-mcp` is a tiny **stdio↔HTTP bridge** with no business logic. The client launches it; it reads `~/Library/Application Support/com.loom/mcp-handshake.json` (`{token, port}`, mode `0600`) and forwards each JSON-RPC line to the app's HTTP endpoint with `Authorization: Bearer <token>`. Still works because the app writes the handshake with whatever port it bound (now the fixed `9092`).

**Two protocol revisions, one endpoint (`MCPProtocol`).** Loom serves **`2026-07-28`** ("modern": no handshake, per-request `_meta` carrying protocol version + client capabilities, `MCP-Protocol-Version`/`Mcp-Method`/`Mcp-Name` mirrored into headers and checked against the body, `resultType` on every result, `ttlMs`+`cacheScope` on `tools/list`, `server/discover`) **and `2025-06-18`** ("legacy": `initialize`). The era is decided **per request from the body** — `_meta` protocol version present → modern; `initialize` → legacy; a bare request → legacy — with the header consulted only to catch a modern-claiming header over a body with no `_meta`, which is a `-32020 HeaderMismatch` rather than something to serve quietly.

Dual-era is one-way: a modern client probes and falls back, a **legacy client cannot fall forward** — dropping `2025-06-18` silently disconnects every client that hasn't rolled over, and answering a modern probe with a quiet `200 OK` latches dual-era clients on "modern" forever, so `UnsupportedProtocolVersionError` (`-32022`, with `supported`) is what makes renegotiation possible. Modern replies use real HTTP status codes (`400` validation, `404`+`-32601` unknown method, `405` on the removed GET/DELETE verbs); **legacy replies stay on `200` even for errors**. `loom-mcp` mirrors body→headers itself (stdio has no headers; the HTTP side requires them). **Not** on the official Swift SDK — adopting it would *lower* the revision Loom speaks (rationale: [ROADMAP § Structured Channel](ROADMAP.md#structured-channel--decided)). The legacy era has a written **retirement condition** rather than an open-ended one (same section), and it is now **measured**: `MCPProtocol.decide` returns the era *and the branch that chose it*, `MCPEraLog` counts the branches apart, and `get_version.protocolTraffic` reports the tally with `legacyEra` as the answer — three-valued (`blocked`/`unknown`/`retirable`) because a `Bool` reading `legacyHandshakes == 0` answered "retirable" on a counter that had seen *nothing*, the tally being per-launch ([ROADMAP § Structured Channel](ROADMAP.md#structured-channel--decided) has the measurement). The separation is the point — an `initialize` handshake proves an old client exists, a **bare request** that declared no era fell back and proves nothing (a stripped header looks the same), so counting them together would give a number that never reaches zero and a condition that never fires.

**Plugin packaging.** The repo root doubles as a Claude Code / Cursor plugin (modelled on KQAR/Reticle): `.claude-plugin/` + `.cursor-plugin/` (`plugin.json` + `marketplace.json`, `source: "./"`), a shared root `.mcp.json` (the HTTP server above), and `skills/loom/SKILL.md` documenting the tools + the debug loop. The MCP endpoint stays **loopback-only on its own port** — deliberately NOT the proxy's `9090`, which binds `0.0.0.0` when LAN device connection is on and would otherwise expose the write-capable, token-optional control plane to the whole Wi-Fi.

There are **three** version fields across those manifests (`.claude-plugin/plugin.json`, `.cursor-plugin/plugin.json`, and the nested one in `.cursor-plugin/marketplace.json` — `.claude-plugin/marketplace.json` has none), and they track the app's `CFBundleShortVersionString`. They are *not* bumped by `release.yml`, which only tags and builds, so a release that touches only `Project.swift` leaves them behind: they sat at 0.0.14 through the whole of 0.0.15 before this was noticed. **`scripts/sync-plugin-versions.sh` propagates the app version into all three** (`--check` reports without writing) — run it in the same `chore(release)` change, which is what the release skill now says. `VersionFieldParityTests` (SharedModelsTests) still fails when one is stale, reading the files through `#filePath`; it is the gate, the script is the way to pass it.

**The plugin and the app version independently, so the skill has the agent check for skew — by reading, never by restating.** The tools an agent can call come from the running app; their prose comes from whatever plugin version is installed. A plugin newer than the app describes tools that aren't there; an app newer than the plugin has tools the skill never mentions. So `skills/loom/SKILL.md` tells the agent to read the plugin's own manifest at runtime (`../../.claude-plugin/plugin.json`, relative to the skill, or the Cursor one) and compare it with `get_version.appVersion`, mention which side is behind once, and carry on — a skew is a stale *description*, never a broken connection, and `tools/list` stays the truth about what exists. **No version literal goes in the skill**: it would be a fifth copy with no build tying it to the other four, and a stale one is worse than none because it makes the agent report a mismatch that isn't there. `VersionFieldParityTests` fails on any `x.y.z` appearing in that file, which is the kind of thing that gets added back while editing prose.

**Two skill directories, two audiences — they are not duplicates, don't merge them.** `skills/` ships *with the plugin* to its users (`skills/loom/SKILL.md` + its `references/`: the tool index, the debug loop, the per-task recipes, and the scrub-before-you-file rules for reporting a Loom bug). `.claude/skills/` is for whoever is *working on this repo* (`release`, `embed-engine`) and is auto-discovered when the project is opened. Moving the latter into `skills/` would ship maintainer procedure — EdDSA key handling included — to every plugin user; moving the former into `.claude/skills/` breaks the plugin, whose skills path is fixed at `<plugin-root>/skills/` (and hard-coded in `.cursor-plugin/plugin.json`). Both stay tracked in git: this file delegates authoritative content to them. Only `.claude/settings.local.json` is ignored.

### MCP Tools

**Write tools are the reason Loom exists.** When adding one, it must be scoped and — if
destructive — gated per [`INTERACTION.md`](INTERACTION.md), it is audited by construction (the
`isWrite` flag derives `writeTools`, so a write tool cannot be added without being recorded), and
**its arguments and edge cases are documented only in its `description` in the registry** — that
text ships with `tools/list`, so the agent already has it and a second copy anywhere else is a copy
that drifts. [`skills/loom/SKILL.md`](skills/loom/SKILL.md) (lazy-loaded) carries the *index* and
delegates recipes to `references/workflows.md`. Don't mirror any of it here.

**Every surface an agent reads is a typed value, never a hand-built dictionary** — the render, the
schema and the arguments each cost a defect to learn that, and each is now checked: `RenderParityTests`
runs a census requiring every stored property of a model to reach a render field or be listed with
the reason it doesn't. **This is the "log it for the human, return it for the agent" rule made
mechanical**, and it is the half that is easier to miss, because the agent-facing gap is the one
that gets noticed. The registry's shape, what adding a tool touches, and the three passes it took:
[`Engine/MCPServer/CLAUDE.md`](Engine/MCPServer/CLAUDE.md).

**What the capture path records, and when, is an engine contract** — a request is recorded when its
head is parsed rather than when it succeeds, an error SwiftNIO raises is Loom's to answer, and a
capture that stops is never silent. WebSocket frames, GraphQL blocks, trailers, the upstream leg's
protocol and the read-through to `flows.sqlite` all live with it in
[`Engine/ProxyCore/CLAUDE.md`](Engine/ProxyCore/CLAUDE.md). Three rules from there generalise to
**anything parsing untrusted network bytes**, so they are worth carrying wherever you are: lengths
decode wide and narrow only once bounded; every remaining-bytes check is a **subtraction**, never an
addition on a wire-supplied length; and "not enough bytes yet" and "these bytes aren't frames" are
**different answers**, never both `nil`.
### Key Modules

| Module | Layer | Responsibility |
|--------|-------|----------------|
| **SharedModels** | base | `Flow`, `ReplayOverrides`, `FlowQuery`, `FlowComparison`, `ProxyControlling` + `ProxyCapability`, `SSLScope`, `CertificateStatus`, HAR — pure value types, no deps. Ships as a public SPM product, so **keep app-deployment detail out of it** |
| **ProxyCore** | engine | SwiftNIO proxy, `ProxyEngine` actor, `FlowStore`, CONNECT tunnel, **SOCKS5 listener** (`SOCKSServer`, `SOCKS5` codec, `ProtocolSniff`), **reverse-proxy endpoints** (`ReverseProxyServer`, `ReverseProxyConfig`), **MITM** (`CertificateAuthority`, `TLSInterceptHandler`, `MITMPipeline`, `CAStore`, `InterceptionConfig`), `UpstreamForwarding` + `UpstreamConnectionPool` |
| **MCPServer** | engine | loopback JSON-RPC HTTP server (fixed port 9092, loopback token-optional), tool registry, handshake writer |
| **ProxyClient** | client | `@DependencyClient` wrapping `ProxyEngine.shared` for TCA |
| **PrivilegedHelperClient** | client | `setSystemProxy` / `systemProxySnapshot(s)` / `restoreOrphanedQUICBlock`, plus the helper's lifecycle (`helperState` / `installHelper` / `uninstallHelper`). Two paths behind one entry point: the root helper when installed and approved, direct `networksetup` + one osascript prompt when not |
| **LoomHelperShared** | shared | The app↔helper contract: XPC protocol, service names, `HelperRequirement`, and `SystemProxyScripts` — the shell **both** sides run |
| **loom-helper** | tool | Root LaunchDaemon (`SMAppService` + XPC), embedded at `Contents/Library/HelperTools/com.loom.proxyhelper` with its plist in `Contents/Library/LaunchDaemons/`. Does the system-proxy + pf (QUIC) work that `/dev/pf` makes impossible un-escalated. Deliberately not CA trust |
| **UpdaterClient** | client | `@DependencyClient` over **Sparkle** (`UpdaterCoordinator` owns `SPUStandardUpdaterController`); silent once-a-day probe + user-initiated check, feeds the panel's footer "Update" button |
| **AppFeature** | feature | TCA reducer + status-bar console (`PanelView`) + main window (`MainView`: table, inspector, Rules/Breakpoints/Audit panels). The proxy's lifecycle, the setup surface, the phone popover and the update check; the captured-traffic half is `CaptureFeature` |
| **Loom** | app | MenuBarExtra entry (panel); boots proxy + MCP server |
| **loom-mcp** | tool | stdio↔HTTP bridge binary |

## Architecture

### Layering (dependency direction is one-way)

```
App → AppFeature → ProxyClient → ProxyCore → SharedModels
                    MCPServer  ─────────────▶ SharedModels
```

Features never depend on each other, and the dependency between a parent and its children runs one way. `AppFeature` is the composition root — the proxy's lifecycle, the console's config surfaces, the phone popover, the update check — and everything else is a child scoped from it: `CaptureFeature` (the window's rows, selection, find bar, sidebar grouping, replay, clear), `SetupFeature`, `RulesFeature`, `AuditFeature`, `BreakpointsFeature`, `ReverseProxyFeature`, `PhoneOnboardingFeature`. A child needing something the parent owns takes it as a **projection** (`setup.port`, `reverseProxy.endpoints`, filled in on read from `status`) and reports what the parent must act on as a **delegate** (`CaptureFeature.Action.Delegate` carries a stamped rule and a failed replay to the surfaces that own them) — never by reaching across. Engine modules never depend on TCA.

There is **no separate map of this graph, deliberately.** `docs/architecture/` held one — nodes, edges and flows, hand-authored, in JSON plus a rendered HTML copy of the same data. Both are gone. It cost what a hand-authored snapshot always costs and paid nothing back: it stopped at M8 (no SOCKS listener, no reverse-proxy endpoints, no mutual TLS, no privileged helper), the two copies drifted from each other, and it went on asserting that the privileged helper could never load for two releases after that was measured false — with a citation, which is worse than a blank. A newcomer reading it would have been misled about four subsystems and one decision.

So the graph above, the [§ Key Modules](#key-modules) table and each module's own `CLAUDE.md` are the map. There are six of the latter now — [ProxyCore](Engine/ProxyCore/CLAUDE.md), [MCPServer](Engine/MCPServer/CLAUDE.md), [AppFeature](Features/AppFeature/CLAUDE.md), [PrivilegedHelperClient](Clients/PrivilegedHelperClient/CLAUDE.md), [workflows](.github/CLAUDE.md), and this file — each holding what is only wrong to not know while working there. Anything reintroduced here must be **generated from the code**, never a second thing to edit.

### Library reuse (SPM)

The two lowest layers ship as SPM library products (`LoomSharedModels`, `LoomProxyCore`) so any
Swift host can embed the engine without Tuist or the app; `swift build` builds them from the root
`Package.swift`, which coexists with `Project.swift`. Embedding details, zero-retention options and
the flow-emission contract: **`.claude/skills/embed-engine/SKILL.md`** (lazy-loaded).

### Concurrency

- **App / Features / Clients**: Swift 6 language mode, strict concurrency.
- **MCPServer**: **Swift 6 language mode**. Its NIO surface is one channel handler, so strict concurrency cost one frozen buffer copy and, until 0.0.24, three JSON-schema statics annotated `nonisolated(unsafe)` / `@unchecked Sendable`. Those are **gone**, and how is the reusable part: they were never about sharing, only about the `[String: Any]` the compiler couldn't see into, so typing the schemas (`JSONSchema`) removed the need for the annotation rather than re-justifying it. What remains here is the two `ISO8601DateFormatter`s and one `JSONEncoder` — genuinely shared Foundation objects, documented at the declaration — plus the event-loop-confined handlers.
- **ProxyCore**: **Swift 6 language mode** too, as of 0.0.16 — but read what that does and does not buy. The channel handlers are still `@unchecked Sendable`, and strict concurrency does not check those, so the gain is on actor boundaries (the three listeners — `ProxyServer`, `SOCKSServer`, `ProvisioningServer` — are now actors like `ReverseProxyServer` already was) and on code written from here on. It is unrelated to the upstream TSan report. Keep NIO code in this module and MCPServer; do not leak channel types across the client boundary.
- **Do not turn on `SWIFT_APPROACHABLE_CONCURRENCY` / `NonisolatedNonsendingByDefault` for ProxyCore.** It is tempting — it cuts the module's strict-concurrency errors from 26 to 6 by keeping `async` nonisolated calls in the caller's isolation domain, which is exactly the shape of `ProxyEngine` calling into its listeners. It also gives every one of those functions an implicit isolation parameter, i.e. **it changes their ABI**: `ProxyCoreTests` (Swift 5, no flag) called them with the old convention and 24 tests died in `_swift_implicitisolationactor_to_executor_cast`. Enabling it everywhere in this repo would not be enough either — `LoomProxyCore` ships as a public SPM product, and a consumer's build settings are not ours to set. The 20 errors it papered over were the honest signal, and making the listeners actors is the fix.
- `ProxyEngine` and `FlowStore` are **actors**; the shared engine is `ProxyEngine.shared`.
- Replay and proxy forwarding use a hand-rolled SwiftNIO upstream client (`NIOStreamingForwarder`) — one production path (`forward` and replay are folds over `forwardStream`), real back-pressure, bounded in-flight bytes, **pooled upstream connections** (`UpstreamConnectionPool`; without it every intercepted request paid a fresh TCP connect *and* TLS handshake to the origin — ~96 ms on a 20 ms server, which is measurably the whole of why Loom felt slow next to Charles) and **a capped capture is never silent**. The full contract lives in [`Engine/ProxyCore/CLAUDE.md`](Engine/ProxyCore/CLAUDE.md) (auto-loads when working in ProxyCore) and [`Engine/ProxyCore/FORWARDING.md`](Engine/ProxyCore/FORWARDING.md) — don't restate it here.

### Conventions

- **Side effects**: always through TCA `Effect` — no async work in views.
- **Reducers never touch NIO**: the engine is reached only through `ProxyClient` (`@DependencyClient` + a `DependencyValues` extension).
- **One write path**: UI and MCP both go through `ProxyEngine.shared`. Adding a write must extend `ProxyControlling`, not bypass it.
- **Bundle prefix**: `com.loom` (personal project — no employer branding anywhere).
- **Everything Loom writes to Application Support is owner-only.** Go through `LoomPaths.createSecureDirectory(at:)` (0700, and it tightens a directory that already exists) and `LoomPaths.restrictToOwner(_:)` (0600) — never a bare `createDirectory`. The CA key was always protected this way; `flows.sqlite` and `audit.sqlite` weren't, and they hold whole request/response bodies and every write tool's arguments. The **directory** mode is the load-bearing part, because SQLite creates `-wal`/`-shm` itself and Loom never gets to chmod them at creation. `client-certificates.json` is the strictest case — it holds private keys and their passphrases in cleartext, same threat model as the CA key — and a test pins its mode rather than trusting the writer.
- **UI**: follow [`DESIGN.md`](DESIGN.md) — semantic system colors, text styles, capsule controls. Never inline hex or fixed font sizes.
- **Performance is a hard requirement, not a nice-to-have.** A capture proxy routinely holds tens of thousands of flows with multi-MB bodies; every list and every large-data render must stay smooth at that scale. Rules:
- **The performance rules are headlines here and measurements there.** Every one of the following
  was a defect first and carries a number; the number, the version that was wrong before it, and
  the test that pins it live with the code that pays for them —
  [`Features/AppFeature/CLAUDE.md`](Features/AppFeature/CLAUDE.md#performance--what-the-window-pays-for)
  for the window, [`Engine/ProxyCore/CLAUDE.md`](Engine/ProxyCore/CLAUDE.md#performance--what-the-store-pays-for)
  for the store. What holds wherever you are:
  - **Never render a large or unbounded collection eagerly** — a lazy container, always, and note
    that `Table` is lazy about row bodies and *not* about its collection, which is why the request
    list owns an `NSTableView` directly.
  - **Update a table by diffing it, never by reloading it**, and let nothing else in the update
    walk the row set either.
  - **Bound what's in memory**, and surface the truncation rather than dropping items silently.
  - **A read must not hold the write actor**, and **a count is a read** — the rule is about
    entering the queue, not about how much work is behind it.
  - **Bodies stay out of line**: list, summary and boot reads are body-free.
  - **Build a batch on a local copy, then assign the observed property once** — a stored property
    of an `@ObservableState` value costs work proportional to what it holds on *every* write.
  - **Aggregate incrementally and coalesce updates**, and aggregate over what is *retained*, not
    over what happens to be in memory.
  - **Prepare a filter or a glob once, not per row** — the same rule on the path an exchange pays
    rather than a list read.
  - **Cheap row bodies**: no per-row date formatter, regex, `JSONDecoder` or `URLComponents`.
  - **A footprint figure is not a memory figure** — ask `malloc_zone_statistics`, and measure each
    configuration in its own process.
- When adding any new list, table or feed, state in the PR how it stays bounded and lazy.
## Release & Auto-Update (Sparkle)

Loom self-updates via Sparkle; a `v*` tag drives `.github/workflows/release.yml` all the way to a
GitHub release with `Loom.dmg` + `appcast.xml`. The full flow and the EdDSA key handling live in
**`.claude/skills/release/SKILL.md`** (lazy-loaded). See also the Sparkle entry in Known Issues.

## Known Issues

**Two rules about this section, because it grows and nothing ever made it shrink.**

*One: an entry is an invariant, not a story.* What belongs here is what a change must not
break and how to recognise the failure. The account of what was tried, what it cost and which
belief turned out to be wrong belongs in [`docs/decisions/`](docs/decisions/) — linked from
the entry, so it is one click away when you are about to re-open the question and zero cost
when you are not. The split is not cosmetic: this file loads in full at the start of every
session, and 24 % of it was postmortem.

*Two: an entry carries the version it was last **verified** in.* These are claims about
tooling, an OS and upstream libraries, all of which move. An unstamped entry is
indistinguishable from one that stopped being true two releases ago, and that has already
cost this project real time — the helper entry said "it could never load" from two refusals
that had never been run, and parked a feature for two releases (`docs/decisions/privileged-helper.md`).
So: when you confirm one still holds, move its stamp. When you can't confirm it cheaply, say
so in the entry rather than leaving the stamp stale — several entries here do exactly that, and
"not re-verified since 0.0.17" is a more useful thing to read than a stamp nobody could back.
An entry several versions behind is a candidate for deletion, not a fact.

**`scripts/verify-known-issues.sh` does the mechanical half**, so a re-check is one command
rather than an afternoon: a pin, a build setting, a symbol that must still exist, a script that
must still pass. It found two drifts on its first run — `NSLock` was "gone from the repo" and is
only gone from every *shipping target*, and "warning-free" is true of the compiler but not of a
naive `grep warning:` (see those two entries). What it deliberately cannot cover: anything
needing a privileged operation (the system proxy, pf/QUIC, the helper's launchd record) or a
measurement (the pre-26 design metrics, the `NavigationSplitView` teardown cost). Those entries
say so themselves. **It now backs entries in two files** — five of its checks pin
[`Engine/ProxyCore/CLAUDE.md` § Known issues (engine-scoped)](Engine/ProxyCore/CLAUDE.md#known-issues-engine-scoped).

*Three: an entry that is only wrong to not know while editing one module belongs to that
module — and where an entry has two readers, it **splits by reader, not by subsystem**.*
A red TSan job and a stalled h2 upload are read by whoever is looking at a red run, on any
branch, so the *tell* stays in § CI beside the paragraph that sends them looking; the
mechanism behind each — the suppression channel, the standalone repro — is only wrong to
not know in the engine, and went there. Splitting the other way is what put a triage tell
900 words from the triage paragraph in the first place. Six went to ProxyCore's own `CLAUDE.md` under the link above — leaf-certificate
serials, the forwarder's header stripping, h2 cookie crumbs, the SSL scope's persistence, the
CA-in-a-file decision, CONNECT ordering. That file loads when the work is there and costs
nothing when it isn't, so the relocation is free in availability and 460 words cheaper per
session. What stays here is what a reader touching *anything* has to know.

- **Four subsystems now carry their own § Known Issues, and the entry that used to be here is a link.** [`Engine/ProxyCore/CLAUDE.md`](Engine/ProxyCore/CLAUDE.md#known-issues-engine-scoped) — leaf serials, header stripping, cookie crumbs, scope persistence, the CA file, CONNECT ordering, the h2 downgrade, both TSan mechanisms, the upload-stall repro, and the scope/drop engine rules. [`Features/AppFeature/CLAUDE.md`](Features/AppFeature/CLAUDE.md#known-issues-surfaces) — the `HStack` container decision, the pre-26 design key, the custom-symbol runtime check, CA trust's three paths, and the scope's human surfaces. [`Clients/PrivilegedHelperClient/CLAUDE.md`](Clients/PrivilegedHelperClient/CLAUDE.md#known-issues-system-proxy) — the whole system-proxy subsystem. [`.github/CLAUDE.md`](.github/CLAUDE.md) — the toolchain pin. Two more went to skills: Sparkle's ad-hoc-signing decision to [`release`](.claude/skills/release/SKILL.md), the entitlements build failure to [`pre-push-checks`](.claude/skills/pre-push-checks/SKILL.md). Each loads when the work is there and costs nothing when it isn't.
- **Tuist ≥ 4.202.5 is required.** *(verified 0.0.24 — `scripts/verify-known-issues.sh`.)* TCA 1.26 pulls swift-navigation 2.10, which uses SwiftPM *package traits* (`condition: .when(traits:)`). Tuist 4.176's graph loader ignores traits and drops the `CasePathsMacrosSupport` macro edge → `Unable to find module dependency`. 4.202.5's loader handles it. `mise.toml` pins **4.202.8** — the top of that maintenance line, taken for `tuist#12243`, "make module map cache hashes checkout-independent". That one is not a generic patch bump: a module map hashed against the checkout it was built in is the mechanism behind the two failures the [§ CI](#ci) cache note is about (`Cycle inside CNIOFreeBSD … Copy Module Map`, then `module map file … not found`), and `TUIST_USE_SWIFTERPM=1` makes the dependency store *shared across worktrees*, so the checkout-dependent hash was live here rather than theoretical. The two CI failures behind that choice, and why it is not a claim that those failures are now impossible — CI still compiles from scratch, which is the actual protection.

- **Every target is on the Swift 6 language mode, test bundles included (0.0.16), and "Swift 6.2" does not mean a language mode.** *(verified 0.0.24.)* The toolchain is Swift 6.2; `SWIFT_VERSION` takes 4/5/6 and there is no 6.2 value, so what 6.2 buys is the *toolchain* (root `Package.swift` is `swift-tools-version: 6.2`) and what the language mode buys is complete concurrency checking. `SWIFT_STRICT_CONCURRENCY = complete` is set once in `Project.swift`'s base settings, so it holds even for a target that ever drops back to `SWIFT_VERSION = 5.0` (there are none now). The `SWIFT_APPROACHABLE_CONCURRENCY` trap in [§ Concurrency](#concurrency) still applies and is unrelated. The four shapes the last three test bundles cost on the way over — `noasync` in an inherited async `defer`, `@Sendable` on the sync bridges, `sending` argument builders, a handler used twice — are in [`docs/decisions/swift6-language-mode-migration.md`](docs/decisions/swift6-language-mode-migration.md).
- **The deployment floor is macOS 15 (0.0.16), and `NSLock` is gone from the repo.** *(verified 0.0.24 — including `Tools/`, whose standalone packages are easy to miss and did carry the last two `NSLock`s; `verify-known-issues.sh` checks the whole repo, not the shipping targets.)* `MACOSX_DEPLOYMENT_TARGET` / `loomDeploymentTargets` / the root `Package.swift` `platforms:` all say 15.0 — change all three or none. What the floor bought: every one of the ~20 `NSLock`-guarded holders (plus 12 test doubles) now keeps its state inside a `Synchronization.Mutex` and conforms to **plain `Sendable`**, so the convention those types used to document is checked instead of asserted. Details and the rules for writing new ones — never `await` inside `withLock`, resume continuations *outside* it, keep the two-section shape around expensive work — are in [`Engine/ProxyCore/CLAUDE.md` § Sendable escape hatches](Engine/ProxyCore/CLAUDE.md#sendable-escape-hatches-what-each-kind-actually-promises). Two things stayed put on purpose: `FlowPersistence`/`AuditPersistence` remain serial-`DispatchQueue`-confined (a non-thread-safe SQLite handle, and writes that must not block the caller — a `Mutex` there is a downgrade), and the event-loop-confined channel handlers still carry `@unchecked Sendable`, which is the `NIOAsyncChannel` rework, not this one.
- **ProxyCore builds warning-free, and new pipeline code has two idioms to keep it that way.** *(verified 0.0.24 — and count the compiler's warnings, not the log's: `appintentsmetadataprocessor` prints ~17 `warning:` lines of its own on every build, which reads as a regression and is not one. `verify-known-issues.sh` counts only lines naming a `.swift` file.)* Construct handlers **inside** `channel.eventLoop.makeCompletedFuture { … }` and add them via `channel.pipeline.syncOperations`; reach for `eventLoop.assumeIsolated()` / `future.assumeIsolated()` when a callback captures `ChannelHandlerContext`. Both with their sites in [`Engine/ProxyCore/CLAUDE.md` § Sendable escape hatches](Engine/ProxyCore/CLAUDE.md#sendable-escape-hatches-what-each-kind-actually-promises). `@unchecked Sendable` on the handler types is genuinely the `NIOAsyncChannel` job and genuinely still unscheduled — but the ~25 warnings this module carried for releases were **not** that job, and the cost of believing they were is in [`docs/decisions/swift6-language-mode-migration.md`](docs/decisions/swift6-language-mode-migration.md).
- **Rules have two stages, and the second one drops rather than hides (0.0.27).** *(verified 0.0.27.)* `RuleActions.dropFromCapture` is the noise filter: matching exchanges are forwarded and answered exactly as they would be without the rule, and **never recorded**. It is evaluated at `FlowStore.upsert` — the one call every producer arrives through (a content exchange, a relayed `CONNECT`, a failed interception, a replay) — while every other action stays in `RuleApplyingForwarder`. That is what "stages" buys: the same matcher, the same list, the same master switch, applied where the decision belongs. Two consequences reach every surface and so stay here: **dropping rather than filtering on read** is what makes the window and an agent's reads agree by construction, and a dropped exchange has no flow and therefore no `appliedRules`, so **`RulesState.droppedCounts` is the only place such a rule can be seen to have done anything** — an absence the operator caused is still an absence. The five rules, the rule-versus-`Route` choice and the group check that was spelled three times: [`Engine/ProxyCore/CLAUDE.md`](Engine/ProxyCore/CLAUDE.md#the-ssl-scope-and-the-capture-drop-stage).

- **The scope is a whitelist, and the unread first run is never silent (0.0.27).** *(verified 0.0.27.)* `toggleSSLTapped` seeds nothing: `include` starts empty and nothing is decrypted until a host is named. The direction is **name it, then decrypt**, which puts the whole weight on the unread or refused origin being *visible* — an unread relay records **no flow at all**, which is byte-for-byte what an agent sees when the client never ran. Two rules hold everywhere and so stay here: **a failed handshake reaches the agent and request table with structured evidence**, while the console stays configuration-only; and **nothing is pre-excluded or auto-excluded**, because guessing would make the whitelist silent again. Engine invariants: [`Engine/ProxyCore/CLAUDE.md`](Engine/ProxyCore/CLAUDE.md#the-ssl-scope-and-the-capture-drop-stage); human surfaces: [`Features/AppFeature/CLAUDE.md`](Features/AppFeature/CLAUDE.md#the-ssl-scopes-human-surfaces); rationale and measurements: [`docs/decisions/ssl-scope-whitelist.md`](docs/decisions/ssl-scope-whitelist.md).



- **The system proxy, the privileged helper and the pf QUIC block are one subsystem, and it lives in [`Clients/PrivilegedHelperClient/CLAUDE.md`](Clients/PrivilegedHelperClient/CLAUDE.md#known-issues-system-proxy).** What holds wherever you are: enabling the system proxy **overwrites** whoever held it and disabling turns the proxy *off* rather than restoring them (Loom cannot know whether that app is still running); the helper is **never load-bearing**, so every path falls through to `networksetup` + one osascript prompt when it is absent, unapproved or silent; and it **does not touch CA trust**, because an ad-hoc signature's caller check is forgeable. An agent can tell which path a `set_system_proxy` will take before calling it — `get_proxy_status.privilegedHelper` and `systemProxyChangePrompts` — because a call blocking on a modal only a human can dismiss otherwise looks like a hang.

  The other three findings (product naming, the missing Info.plist section, the poisoned launchd label), and the postmortem of the helper deleted in 0.0.16 — including the lesson that outlived it, **a claim about what the platform refuses is a measurement, not a deduction** — are in [`docs/decisions/privileged-helper.md`](docs/decisions/privileged-helper.md).
