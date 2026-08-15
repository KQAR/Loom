# Decision records

Long-form records moved out of [`AGENTS.md`](../../AGENTS.md), which loads in full at the
start of every session and had grown to ~24 % postmortem.

The split is by **kind of statement**, not by topic:

- `AGENTS.md` holds the **invariant** — what a change must not break, and how to recognise
  the failure. It stays short enough to read every time.
- A file here holds the **record** — what was tried, what it cost, which belief turned out
  to be wrong. Read it when you are about to re-open the question; skip it otherwise.

Each `AGENTS.md` entry links to its record, so nothing is lost, and each record links back
to the section whose invariant it produced.

| Record | The invariant it produced |
|---|---|
| [`ci-red-run-triage.md`](ci-red-run-triage.md) | A red run on `main` is not automatically a regression — and the three other things it can be |
| [`privileged-helper.md`](privileged-helper.md) | The helper's four hard rules, and why it will never install CA trust |
| [`tsan-continuation-race.md`](tsan-continuation-race.md) | A red TSan job means something now: ask whether Loom code *performs* the racing access |
| [`h2-upload-stall.md`](h2-upload-stall.md) | The stall signature is `consumed = 65535` exactly; reads-issued does not distinguish it |
| [`navigation-split-view.md`](navigation-split-view.md) | `MainView` is a plain `HStack`, and three measured dead ends around it |
| [`navigation-split-view-kvo.md`](navigation-split-view-kvo.md) | The two-round investigation behind the entry above — sample stacks, A/B matrix, lldb findings |
| [`websocket-capture.md`](websocket-capture.md) | Parsing untrusted bytes: decode lengths wide, check remaining by subtraction, and never answer "not yet" and "not frames" the same way |
| [`write-path-memory.md`](write-path-memory.md) | A footprint figure is not a memory figure — ask `malloc_zone_statistics`, and measure each configuration in its own process |
| [`ssl-scope-whitelist.md`](ssl-scope-whitelist.md) | Name it, then decrypt — and the unread or refused origin must be visible on all three surfaces |
| [`rules-drop-stage.md`](rules-drop-stage.md) | `dropFromCapture` is a rule, obeys `RulesState.applies`, and drops rather than filtering on read |
| [`h2-cookie-crumbs.md`](h2-cookie-crumbs.md) | The model holds one `cookie` field; the crumb split is an encoding applied on the h2 leg |
| [`swift6-language-mode-migration.md`](swift6-language-mode-migration.md) | The four shapes the last test bundles cost, and why ~25 warnings were never the `NIOAsyncChannel` rework |
| [`entitlements-modified-during-build.md`](entitlements-modified-during-build.md) | Never `.dictionary` — Tuist rewrites the mtime, Xcode calls that "modified", and the failure sticks |
| [`capture-path-performance.md`](capture-path-performance.md) | Every number in § Architecture's performance rules, plus the six versions that were wrong (one slower than what it replaced) |
| [`mcp-typed-surfaces.md`](mcp-typed-surfaces.md) | One hole — a dictionary the compiler can't see into — closed in three passes: render, schema, arguments |
| [`h2-header-block-downgrade.md`](h2-header-block-downgrade.md) | Drop ALPN `h2` for a host whose first header block trips the pre-ACK HPACK limit — and mark every flow |

## Writing one

Move text here when it is *history* — an incident, a rejected design, a measurement that
settled an argument. Leave the one or two sentences a reader needs in order to not break the
thing, and link. Do not summarise the record in `AGENTS.md` beyond that: two versions of the
same story is the problem this split exists to end.

Records are **not** maintained. They are dated, and they describe the state at that date; if
one is contradicted by later work, the `AGENTS.md` invariant is what gets corrected, and the
record gains a note saying so rather than being rewritten.
