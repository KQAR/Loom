# One hole, three surfaces: how the agent-facing `[String: Any]` was closed

> Moved out of `AGENTS.md` on 2026-08-15, unedited but for the linking sentences. It is a
> **record**, not an instruction: what was tried, what it cost, and why the current shape is
> the shape. The invariants it produced live in `AGENTS.md` § Core Concepts, which links here —
> read that first; come here when you are about to re-open the question.

Every agent-facing surface had the same defect in a different place: a value the compiler could
not see into, sitting between a model that grows and an agent that reads. It was closed in
three passes, 0.0.19 and 0.0.24, and each pass found the previous one's blind spot.

## 1. The render (0.0.19)

Every model an agent reads had *two* representations — the model (`Codable`, so the compiler
grows it) and a `[String: Any]` render built by hand — and only the first grew when a field was
added. Adding a field to `Flow` compiled everywhere while the agent silently never saw it.

That is the same hole `RuleCodecParityTests` was written for **after it had already cost rules
a field**, and it was open on every other model. `diff_flows` was the one render left out of
the sweep that fixed it, and closing it (`FlowDiffRender` & co.) removed the last place a new
`FlowComparison` field could compile everywhere and reach nobody.

The DTOs' JSON is byte-identical to what the dictionaries produced — that pass was a refactor
of the renderer, not of the agent-facing surface.

## 2. The schema (0.0.24)

The *input* half stayed open for four more releases. Every tool's `inputSchema` was a
`[String: Any]` literal, so `MCPToolSchemas.swift` was **1 100 lines the compiler could not
read**: a misspelled keyword, a `required` naming a property no `properties` declares, an
`items` on a node that never said `"type": "array"` all compiled and shipped to the agent.

It also *forced* the escape hatches — `MCPTool: @unchecked Sendable`, the shared sub-schemas
`nonisolated(unsafe)` — which then said nothing about what a future edit could break. And it
made `MCPArgumentValidation` re-derive the shape at runtime through `as?` casts, so a node it
couldn't decode validated nothing, silently.

Worth noting the shape of the fix: the annotations were never about sharing, only about the
dictionary the compiler couldn't see into, so typing the schemas *removed the need* for them
rather than re-justifying them.

The emitted `tools/list` JSON is unchanged but for `set_rule`'s `"required": []`, which is now
absent (JSON Schema reads the two identically).

## 3. The arguments (0.0.24)

Handlers took the raw `[String: Any]` and reached in with `as?`. Three costs, each of which had
already shipped as a defect:

1. **A wrong-typed value read as absent.** `(arguments["only_errors"] as? Bool) ?? false` turns
   `"true"` into `false`, and `arguments["limit"] as? Int` turns a JSON `20.0` into the default
   — the silently-unapplied filter `MCPArgumentValidation` exists to prevent one layer up.
2. **Numeric spelling handled per call site.** `since_seconds` accepted both spellings; every
   other number took whichever cast its author wrote.
3. **Nothing checked that a handler reads what the tool advertises**, and that one was live:
   `resume` read `id` as an alias for `pending_id` and its description promised "either
   argument name works", but the schema never declared `id`, so `validateArguments` refused the
   call at the choke point *before the handler ran* — a false promise for four releases, found
   by this pass and fixed by declaring it.

The result is stricter than before **by design**: `only_errors: "true"`, `group: 3` and
`recording: "off"` are now errors rather than silently-dropped arguments.
