<!-- Loaded only when working under Engine/MCPServer/. The tool registry's own contract, which
     used to sit in the always-loaded root AGENTS.md. What the tools are *for* is the plugin skill
     at skills/loom/SKILL.md; the two protocol revisions are the root AGENTS.md § The AI link. -->

# MCPServer — the tool registry's contract

The agent is Loom's primary operator, so everything here is a surface it reads. One rule underneath
the rest, and the root file states its general form: **a fact the engine holds that decides whether
an operator's action was correct must be reachable from a tool.** Logging it is for the human;
returning it is for the agent, and doing only the first is the defect this module keeps re-learning.

## Where a tool's documentation lives

Each tool's arguments and edge cases live **only** in its `description` in the registry at
`Engine/MCPServer/Sources` — that text ships with `tools/list`, so the agent already has it, and a
second copy anywhere else is a copy that drifts. [`skills/loom/SKILL.md`](../../skills/loom/SKILL.md)
(lazy-loaded) carries an *index* — name → what it's for, read/write grouping, the debug loop they
compose into — and delegates the rest: `references/workflows.md` (recipe per task + what an empty
capture or a blind tunnel actually means), `references/filing-a-bug.md` (known non-bugs + the
scrub-before-you-post rules). Progressive disclosure is the reason for the split, so don't grow the
SKILL body back: a new per-tool caveat belongs in the tool's `description`, a new recipe in
`workflows.md`. Don't mirror any of it here.

## The registry's shape

That registry is split by concern: `MCPToolSchemas.swift` is everything `tools/list`
advertises, `MCPToolExecutor.swift` is the state + the `call` dispatch/audit choke point, and
`MCPTools+<domain>.swift` (Environment / Flows / Waits / Replay / HAR / Rules / Breakpoints /
Rendering) holds the handler bodies. **Adding a tool touches two places** — one `MCPTool` value in
`MCPToolExecutor.tools` (name, description, input schema, `isWrite`, handler) and the handler
function itself. `toolDefinitions`, the name→tool dispatch index and `writeTools` are all derived
from that one table, so advertised-but-undispatchable, dispatchable-but-unadvertised and
write-but-unaudited are no longer states this code can be in; what `MCPServerTests` still checks is
what a value can't express — that a duplicate name doesn't shadow a handler, and that a tool flagged
`isWrite` also *says* "This is a write action." to the agent.

## Typed surfaces — one hole, closed three times

**A render is a typed value, not a hand-built dictionary (0.0.19).** Every model an agent reads had *two* representations — the model (`Codable`, so the compiler grows it) and a `[String: Any]` render built by hand — and only the first grew when a field was added, so adding a field to `Flow` compiled everywhere while the agent silently never saw it. The renders are `Encodable` DTOs in `MCPRenderModels.swift`, turned into JSON in one place (`MCPRender.dict`), and `RenderParityTests` runs a **census**: every stored property of the model must reach a render field or be listed with the reason it doesn't (folded, renamed, deliberately absent) — and a stale reason fails too. `diff_flows` was the last render outside that sweep and is in now (`FlowDiffRender` & co.). Two rules for a new render: a flag that only ever means `true` is `Bool?`, never `Bool` (a `false` would add a key that was never there), and shaping is welcome (`ttfbMS` is computed, `captureTruncated` folds four fields) as long as the reason lands in the census. This and the two entries below are three passes at one defect; how each found the previous one's blind spot is in [`docs/decisions/mcp-typed-surfaces.md`](../../docs/decisions/mcp-typed-surfaces.md).

**And so is a schema (0.0.24).** Every tool's `inputSchema` was a `[String: Any]` literal, so `MCPToolSchemas.swift` was 1 100 lines the compiler could not read — a misspelled keyword, a `required` naming a property no `properties` declares, an `items` on a node that never said `"type": "array"` all compiled and shipped to the agent, and `MCPArgumentValidation` re-derived the shape at runtime through `as?` casts, so a node it couldn't decode validated nothing, silently. Schemas are `JSONSchema` values now (`MCPSchema.swift`, serialized in one place by `JSONSchema.json`), `MCPTool` is plainly `Sendable`, and the vocabulary is deliberately only what Loom's tools use. One distinction in that type is load-bearing and is the reason it isn't "a dictionary with types": **`properties: nil` and `properties: [:]` are different schemas** — nil is a free-form map (`set_headers`, `match.query`), where any key is legal, and `[:]` is a tool that takes no arguments, where none is. `MCPArgumentValidation` returns early on the first, so collapsing them would switch unknown-argument rejection off for every no-argument tool — which is why `MCPSchemaTests` pins that **every** advertised tool is an object with non-nil properties, the one shape that can't be checked at the declaration.

**The arguments are read against that schema, not cast out of an `Any` (0.0.24).** Handlers took the raw `[String: Any]` and reached in with `as?`, which cost three things and each one had shipped as a defect — a wrong-typed value read as absent (`only_errors: "true"` → `false`), numeric spelling handled per call site, and nothing checking that a handler reads what the tool advertises. So `JSONValue` (a checked `Sendable` JSON tree) is built **once** in `MCPToolExecutor.call`, `MCPArguments` reads it against the tool's own schema node, and every accessor throws `invalidParams` naming the key, its dotted path (`actions.map_local.path`) and what it expected. Three rules: **`Any` is allowed only at the two Foundation boundaries** — what `JSONSerialization` hands in, what it consumes for the audit render — and a third occurrence is a value the compiler can't check for no benefit; **a read of an undeclared key trips an assertion** (debug + every test run), because such a read can never fire in production; and **integers and doubles stay apart**, so `int` can reject `2.5` instead of truncating it and the audit trail records the `20` the agent sent rather than `20.0`. `.forTool(name, values)` is how a parser is exercised in isolation with the declared-key check still on. Stricter than before by design: `only_errors: "true"`, `group: 3` and `recording: "off"` are now errors rather than silently-dropped arguments.

## The audit trail

Every MCP **write** tool call is recorded in a durable **audit trail** (`~/Library/Application Support/com.loom/audit.sqlite`, row-capped, survives relaunch): the choke point is `MCPToolExecutor.call`, which records an `AuditEntry` (tool, arguments, success/failure, detail) for each tool in `MCPToolExecutor.writeTools` — read tools are never logged. The engine owns an `AuditStore` (actor + fan-out, sibling of `FlowStore`) exposed via `AuditControlling` (`recordAudit` / `recentAuditEntries` / `auditStream`); the supervising human reads it in the main-window **sidebar → Audit** panel (`AuditPanelView`, read-only newest-first timeline), and an agent reads it back via `get_audit_log`. `writeTools` is derived from each tool's `isWrite` flag rather than kept as a parallel list, so a write tool cannot be added without being audited; `MCPServerTests` still pins the flag against the "This is a write action." marker the agent reads, because prose and flag have different readers and neither can be derived from the other.
