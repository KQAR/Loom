# The capture-path performance round: the measurements, and the six versions that were wrong first

> Moved out of `AGENTS.md` on 2026-08-15, unedited but for the linking sentences. It is a
> **record**, not an instruction: what was tried, what it cost, and why the current shape is
> the shape. The invariants it produced live in [`AGENTS.md` § Architecture](../../AGENTS.md#architecture) and [§ Conventions](../../AGENTS.md#conventions), which
> links here — read that first; come here when you are about to re-open the question.

Every rule in that section carries one number, because a number is what tells you a regression
happened. What is here is the rest: the dead ends, the versions that came out *slower* than
what they replaced, and the methodology behind figures that look arbitrary.

Unless said otherwise, figures are the 20 000-row window with a capture batch landing ten times
a second.

## The table: why the diff computes structure only

`reloadData()` discards every realized cell to rebuild identical content: **380 ms reload vs
42 ms diffed** on a 2 000-row table applying one batch, and the diffed path stays flat as the
capture grows (46 ms at 20 000) because it costs the viewport rather than the capture.

Three rules hold that up, each measured rather than assumed:

- the diff computes **structure only** — a head trim and a tail append. Finding *which* rows
  changed meant a `Flow` comparison per retained row, which scaled with the capture;
- content correctness comes from refreshing the **visible** rows, since an off-screen row is
  rebuilt from current data the moment it scrolls in;
- a cell re-hosts its SwiftUI content only when a **draw-relevant** comparison says it moved,
  because assigning `rootView` runs an update transaction whether or not the value changed.

**The one that outlived all three** was the selection sync: it opened with
`rows.firstIndex { $0.id == id }`, a linear scan of the window on every batch to conclude,
almost always, that nothing had moved — 3.08 ms with a selection against 1.06 ms without. It
asks the *table* where its selection is now (O(1), and correct because `NSTableView` shifts its
own index across the `removeRows`/`insertRows` that already ran), keeping the scan only for a
`.reload` or a selection the store moved.

`RequestTableSelectionTests` pins the **overhead ratio at ≤1.5×** rather than a time, because
an update at 20 000 rows genuinely costs 14× one at 1 000 for AppKit's own reasons, and a
cross-size assertion would measure that instead.

## The tail-follow: what it looked like before

A batch used to fade its rows in *and* jump the viewport by the whole batch, ten times a
second, so the list blinked forward rather than moving and each batch's fades overlapped the
next into a shimmer. Row-edit animations are gone; the motion belongs to the scroll.

Three rules, each of which was a bug:

- whether to follow is measured from the viewport's **geometry** a moment before the edit
  lands, never from a flag — a flag can only be cleared by a scroll notification, and those
  miss momentum, scroller drags, keyboard scrolls and the table's own head-trim shift, so it
  stays armed and the list yanks itself down while someone is reading;
- an **in-flight glide counts as being at the bottom**, since it is behind the bottom by
  construction;
- **nothing programmatic touches the offset during a gesture** or for half a second after,
  because the glide and a live scroll write the same clip view and the interleaved
  `boundsOrigin` writes shake the list — visible only once a column is dragged wide enough to
  scroll horizontally, where the two axes disagree.

## A read must not hold the write actor — and neither must a count

On a full 2 000-flow ring a host-filtered read costs 2.1 ms, and an upsert costs 0.014 ms quiet
against **1.8 ms while such reads ran (127×)**; off the actor it is back to 0.015 ms.

**The sequel is the interesting half.** That entry read as settled while the same defect sat
one layer down, in the cheapest-looking call in the store: `FlowPersistence.storedRowCount`
opened with `queue.sync { writePending() }`, so asking "how many flows are retained" forced a
synchronous SQLite transaction of up to 256 rows — on the queue batched writes flush on, while
holding the `FlowStore` actor. It reached the hot path through `ProxyEngine.status()`
(`FlowStore.retainedCount`), which is not a rare read: the window's audit fan-out re-reads it
after every agent write, `.viewAppeared` on every panel open, and `get_proxy_status` is a poll
the skill encourages. `FlowStore.search` and `page`'s `totalRetained()` had it too.

The count is mirrored out of the queue now (`approximateStoredRowCount`) with the pending batch
included — which is all the drain was buying. The reusable half: **a scan announces itself as
expensive and a count does not**, so the rule is about *entering the queue*, not about how much
work is behind it.

## The boot fold: 383 ms, of which 3.6 ms was SQLite

`FlowPersistence.aggregate()` runs once per launch over everything retained and decoded the
whole table to do it — 20 000 rows, **383 ms, of which 3.6 ms is SQLite**; the rest was
`JSONDecoder`, spent on the store's serial queue, i.e. in front of the batched capture writes
while a capture is already running. As columns and a `GROUP BY`: **13 ms**.

A freshly backfilled file measures **~51 ms rather than 13** — 20 000 `UPDATE`s leave the pages
fragmented, and it converges as rows are replaced and pruned. Worth knowing before reading the
first post-upgrade launch as a regression.

## Observed state: the shape was always wrong, only the size made it show

A stored property of an `@ObservableState` value costs work proportional to what it holds on
*every write*: one insert through the state is **690 µs** against **2.6 µs** into a plain
`IdentifiedArray`, so mutating it once per flow made a batch quadratic — **14 s to fill the
window against 90 ms** building on a local copy and assigning once.

It was invisible at the old 2 000-row cap and appeared the moment the cap moved.

## The cached projection, and the fold that was slower than the rebuild

`displayFlows` is recomputed from a single funnel (`refreshVisibleFlows`) driven by `didSet` on
the inputs, not by call sites remembering — the first version relied on call sites and rendered
wrongly and silently **in six tests**. The sidebar's three grouping lists were the last thing
still sorting on read: 0.60 ms for the three, per render, against 0.001 ms now.

Caching is not enough once the cache is rebuilt at capture rate. With a category or a needle
selected, refreshing filtered the whole window on **every** batch: **7.9 ms for a host category
and 8.9 ms for a needle against 1.8 ms unfiltered**, ten times a second, to re-derive a list
that changed by the thirty rows the batch carried. Folding the batch in instead costs 1.7 ms
and 3.2 ms.

Two things that fold got wrong first, both worth knowing:

- the batch's own emission order is **not** the capture's — a slow exchange completes after a
  faster one started, so the tail is appended in insertion order, not as seen;
- the first version mutated the projection *through* observed state and came out **slower than
  the rebuild it replaced — 44 ms against 8.9** — until it built on a local copy and assigned
  once, the same rule `recordFlows` already states.

## The trim, and the invariant it cost

`IdentifiedArray.removeFirst` shifts the backing storage and rebuilds the id index, so it costs
the whole window however few rows it drops: at the cap a steady-state batch was **1.79 ms
against 0.25 ms** below it, all of it this call, because trimming exactly to the cap leaves the
next batch over again.

The cost is one invariant, stated rather than quietly dropped: recording flows one at a time
and as a batch no longer leave the same *number* of rows, because they cross the cap at
different moments. What still holds — and what
`batchRecording_matchesPerFlowRecording_atTheCap` pins — is that the two are suffixes of the
same capture agreeing on every row they both hold.

## Preparing a filter: where the time actually was

`FlowQuery.matchesMetadata` did the query's own share of the work inside the loop: the host
pattern was lowercased again for every flow (and the flow's host materialized as a `String`
even for a literal pattern), `url_contains` went through `range(of:options:.caseInsensitive)` —
an `NSString` bridge and a grapheme walk — the `header_contains` needle was re-split and
re-encoded to bytes per flow, and `ByteSearch` re-folded the needle's case inside every call.

Per scan over a full 2 000-flow ring: `url_contains` **8.3 → 1.0 ms**, `header_contains`
**7.2 → 2.8 ms**, a host glob **4.8 → 3.6 ms**, the three combined **9.8 → 4.3 ms**.

`matchesMetadata` remains as the one-shot spelling and is now *slower* per call, which is the
honest trade and is said at the declaration. This is `FlowSearch.predicate()`'s rule
(84 ms → 0.76 ms per keystroke) applied on the side an **agent** pays for — `wait_for_flow`
re-scans on every emission of the flow stream.

## The glob: three costs, and only one of them was the obvious one

`RuleEngine.matchingRules` and `BreakpointStore.firstMatch` both run the whole predicate list
on the **event loop for every request**. Over 1 000 requests against 50 glob rules:
**107 ms → 9.4 ms** (0.107 → 0.0094 ms of event-loop time per request), split three ways:

1. **The match itself.** Preparing the pattern removes only a third (107 → 74 ms), because
   Foundation's Unicode-correct search — not the preparation — was **97 %** of it. `Glob.Pattern`
   matches over case-folded bytes now, the same boundary `ByteSearch` draws for body search.
2. **Preparation.** `Glob.pattern(for:)` is a bounded process-wide cache, `RegexCache`'s shape
   and reasoning, so every caller with only a string gets it without plumbing.
3. **The request.** `RequestMatchContext` parses the URL once for the whole list instead of
   once per rule carrying a `query` (`URLComponents` ×50), and encodes it once instead of once
   per glob rule; a query-scoped list of 10 went 9.3 → 1.7 ms on this alone. Its derivations
   are **lazy**, because encoding the URL eagerly made the prefix and exact styles *slower*
   (5.3 → 8.7 ms per 1 000 at 50 rules) for a value they never read.

### Taking the remaining headroom, and the rejected fix

The remaining ~70 % was the cache lookup — a string hash plus a lock acquire per rule per
request. The obvious fix, **a prepared rule list owned by `RulesConfig`/`BreakpointStore`, was
the wrong one**: it buys a second object that must be rebuilt in step with every mutation, i.e.
a staleness bug waiting for the one write path that forgets. The pattern is prepared on
`RuleMatch` itself (`preparedGlob`), rebuilt by `didSet` on the only two inputs it derives
from, so there is no lifetime in which the pair disagrees.

Over 200 all-glob rules (release, per request): **0.0246 ms → 0.0110 ms**, against a floor of
0.0094 with nothing but the patterns in hand.

**Half of that win is not the lookup at all, and it generalises past this module**:
`for rule in rules` **copies each rule** to ask a question about it, and a `RuleMatch` carries
five refcounted fields — so the same loop by index costs 0.0188, and by index through
`TrafficRule.matches` (which never lifts the match out of the array) costs 0.0110. A list
walked per request is walked by index.
