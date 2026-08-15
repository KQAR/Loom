# `dropFromCapture`: why it is a rule, and why it drops instead of filtering

> Moved out of `AGENTS.md` on 2026-08-15, unedited but for the linking sentences. It is a
> **record**, not an instruction: what was tried, what it cost, and why the current shape is
> the shape. The invariants it produced live in `AGENTS.md` § Known Issues, which links here —
> read that first; come here when you are about to re-open the question.

## A rule, not a list of its own

That was the second design and the better one: the whole `RuleMatch` vocabulary comes free
(url / method / host / query / `sourceApp` / `deviceIP`, so "don't capture this app's health
checks" is expressible), along with groups, per-rule enablement, the editor, the seven MCP
tools and the audit trail.

It is **not a `Route` case beside `.block`** — block stops the request from happening, this
only stops it being kept, and one mistyped word between them costs real traffic. It lives in
the editor's **Advanced** section for the same reason, since it is the one action that changes
nothing about the traffic.

## The group check that was spelled three times

Both matchers spelled the liveness predicate themselves, and both had it wrong the same way:
`rule.isEnabled` alone, reading straight past `disabledGroups`, so a switched-off scenario went
on rewriting and dropping. The behaviour was fixed by spelling the group check twice more, and
`RulesState.applies` is the same fix with one definition behind it and expiry folded in.

What hid the original is that every group test asserted on `activeRules`, the one projection
the engine deliberately avoids (it allocates a second array per exchange on the event loop).
So the predicate is now asserted from the engine's side as well as the model's.

## Dropping rather than filtering on read

Filtering would make consistency a property every read path has to remember (`recent`,
`recent(matching:)`, `scan`, `assemblePage`, the aggregates, `get_stats`, `wait_for_flow`,
`export_har`), and forgetting one is a silent disagreement between two surfaces. Dropping at
`FlowStore.upsert` makes the window and an agent's reads agree by construction.

The consequence, stated rather than discovered: disabling the rule brings nothing back.
