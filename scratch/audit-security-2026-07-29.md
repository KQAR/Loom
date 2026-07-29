# Security & privacy audit — 2026-07-29

**Counts**: HIGH 2 · MEDIUM 1 · LOW 1. No CRITICAL. No previous audit for this area.

Threat model understood as stated in CLAUDE.md: Loom decrypts HTTPS on purpose, keeps the
root CA in a 0600 file on purpose, and leaves the loopback MCP endpoint token-optional on
purpose. Those are not reported as defects. What follows is where the code departs from
its *own* stated protections.

Clean: no hardcoded secrets anywhere (`AKIA…`, `sk-…`, `ghp_…`, `BEGIN…PRIVATE KEY` — zero
matches outside test placeholders). No tokens in `UserDefaults`/`@AppStorage` (only pins,
the LAN flag, device aliases, the update-probe timestamp, the SSL scope). MCP token is
`UUID().uuidString` (122 bits) in a 0600 file, and `constantTimeEqual`
(`MCPServer.swift:343-349`) really is constant-time. `MCPServer.swift:117` binds
`127.0.0.1` only — the LAN rebind is the capture port, not the control plane. Every
`Log.*` call surveyed logs paths, tool names, IDs and error text; none logs header or body
content, and `privacy: .public` is only ever on non-secret metadata.

---

## HIGH — `flows.sqlite` / `audit.sqlite` don't get the permissions the rest of the code insists on

`Engine/ProxyCore/Sources/FlowPersistence.swift:56-73`
`Engine/ProxyCore/Sources/AuditPersistence.swift:26-44`

`CAStore.swift:119-124` creates its directory `0700` and chmods the file `0600`.
`Handshake.swift:27` chmods `0600`. `RulesConfig` does the same. These two do a bare
`createDirectory(withIntermediateDirectories:)` with no attributes and never call
`setAttributes`, so the DB files land at whatever the process umask gives — typically
0644 under a 0755 directory.

What's in them: **full captured request and response bodies** (passwords, session tokens,
PII) and **full MCP write-tool arguments** (which carry header/body overrides from
`replay_flow`, paths from `mapLocal`, …). That is a strictly larger secret surface than
the CA key the code went out of its way to protect.

On a multi-user Mac any other local account can read the entire traffic history off disk.

**Fix**: same pattern as `ca-store.pem` — `0700` on the app-support directory, `0600` on
`flows.sqlite` and `audit.sqlite` (and their `-wal` / `-shm` siblings) after
`sqlite3_open`.

*(Verified: `grep setAttributes|posixPermissions` returns hits in `CAStore` and
`Handshake`, none in either persistence file.)*

## HIGH — `export_har(redact: true)` leaves bodies and WebSocket frames intact

`Engine/MCPServer/Sources/MCPTools+HAR.swift:60-82`, `SharedModels/Sources/FlowRedaction.swift:52-54`

`redact: true` scrubs credential headers and known token query keys. Bodies survive unless
the caller *also* passes `redact_bodies: true` (`dropBodies` defaults to `false`). And
`FlowRedaction` contains **zero references to `webSocket`** — WS text frames are never
touched, redacted or not.

The separate flag is documented in `skills/loom/SKILL.md` and the "a debugging export
usually needs the tokens" default is a deliberate call. The problem is the naming: `redact:
true` reads as "safe to share now". A login POST body, or a JSON response carrying a
session token, survives it untouched — which is precisely the leak the feature exists to
prevent when someone attaches the HAR to a public bug report.

**Fix**: either make `redact: true` imply `dropBodies` (opt back *in* to bodies
explicitly), or have the tool response say plainly that bodies and WS frames were not
redacted whenever `dropBodies` is false. Either way, extend `FlowRedaction` to cover
`webSocket.messages`.

*(Verified: `dropBodies: Bool = false` in the initializer; no `webSocket` match in the
file.)*

## MEDIUM — token-optional loopback + unconfined `mapLocal` path

`Engine/MCPServer/Sources/MCPServer.swift:332-339`, `Engine/ProxyCore/Sources/RuleApplyingForwarder.swift:163-181`

Not a bug in isolation — it's the documented tradeoff that lets the plugin connect with no
per-launch config. Flagged for the capability it compounds into: *any* local process, not
just the intended AI client, can `set_rule` a `mapLocal` action pointing anywhere
(`~/.ssh/id_rsa`, …) with no path confinement, then trigger it with a matching request
through the proxy — including from a phone on the same Wi-Fi when LAN capture is on.
`import_har`'s `path` (`MCPTools+HAR.swift:88`) is likewise unconfined, though its blast
radius is smaller (the target must parse as HAR JSON).

Note the asymmetry: `export_har` *does* confine output to `exports/` and strips directory
components from `filename`. The read side got no equivalent.

**Fix**: accept explicitly, or confine `mapLocal.path` to an allowlisted fixtures
directory the way `export_har` confines its output.

## LOW — write-then-chmod race on `ca-store.pem` / `rules.json`

`Engine/ProxyCore/Sources/CAStore.swift:116-125`, `RulesConfig.swift:103-119`

`Data.write(options: .atomic)` creates a temp file at umask permissions and renames it in;
`setAttributes(0o600)` runs after. Microsecond window where the CA private key is
world-readable. Single-user dev machine, so barely worth acting on — but the comment
claims "protected by file permissions", and for a few microseconds it isn't.

**Fix**: pre-create with mode `0600` via `open()`/`FileHandle` instead of chmod-after-write.

---

## Checked and *not* issues

- `SystemProxyApplier` / `QUICBlocker` interpolate into `/bin/sh -c` and `osascript … with
  administrator privileges` — looks like textbook injection, but `host` is the hardcoded
  literal `"127.0.0.1"`, `port` is an `Int` (the proxy's own bound port), and
  `set_system_proxy`'s only argument is `enabled: Bool`. `QUICBlocker`'s paths are
  compile-time constants under root-owned `/var/root/com.loom`. No attacker-controlled
  input reaches either script.
- `NSAllowsArbitraryLoads: true` — required; a proxy forwards arbitrary upstreams.
- `KeychainCAStore`'s `kSecAttrAccessibleAfterFirstUnlock` — reference-only code per
  CLAUDE.md; the live path is `FileCAStore`.
- No `PrivacyInfo.xcprivacy` — not App Store distributed, so not a rejection risk.
- `BinaryValidator` correctly requires an Apple-anchored signature before the root helper
  execs a system binary.

## Order to fix

1. chmod the two SQLite files (+ `-wal`/`-shm`) to 0600 under a 0700 directory.
2. Close the `redact: true` body/WebSocket gap — default or loud warning, plus WS coverage
   in `FlowRedaction`.
3. Decide deliberately whether `mapLocal` / `import_har` get the path confinement
   `export_har` already has.
