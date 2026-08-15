# NavigationSplitView's quadratic KVO teardown (why `MainView` is not a `NavigationSplitView`)

The conclusion lives in [AGENTS.md § Known Issues](../../AGENTS.md#known-issues) and DESIGN.md `{components.main-window}.structure`:
**do not swap `MainView` back to `NavigationSplitView`.** This page is the full two-round
investigation record backing that decision, kept so nobody has to re-earn it.

> **Later note (0.0.19).** This record was written when the replacement was `HSplitView`, and says
> so throughout. `HSplitView` was dropped afterwards as well — a bare `NSSplitView` has no collapse
> semantics, so the sidebar could only be inserted and removed, which pops. `MainView` is a plain
> `HStack` animating the pane's width; see
> [`navigation-split-view.md`](navigation-split-view.md). Nothing below
> changes: the measurement, the stacks and the A/B matrix are all about `NavigationSplitView`, and
> that half of the conclusion is unaffected. Per `docs/decisions/README.md`, a record earns a note
> rather than a rewrite.

## The symptom

Switching sidebar category re-diffs the whole request table, and inside `NavigationSplitView` that
means instantiating every row. Measured at ~1250 captured flows: a category switch costs **14–16 s
of main thread** and evaluates ~1200 row bodies (a table this size should evaluate a screenful,
~40). The work is not in anything Loom does per row — every instrumented piece of it sums to
~18 ms, 0.1 % of the total. A `sample` during the stall lands in `NSTableView endUpdates` →
`NSTableRowData _updateVisibleViewsBasedOnUpdateItems` → `NSHostingView.viewWillMove(toWindow:)` →
`removeObserver:forKeyPath:` → `NSKeyValueShareableObservationInfoNSHTHash`: **KVO observer
removal**, whose shared observation info is rebuilt per removal, so the cost is quadratic in how
many row hosting views the update pass created. Confirmed quadratic by capping the rows handed to
the table — 300 rows → 0.93 s, 600 → 3.8 s, 1250 → 14 s (row count ×2.08 → time ×3.8).

## The trigger is the container, and only that container

Replacing `NavigationSplitView` with `HSplitView` or an `HStack` + `Divider` — same sidebar, same
7-column table, everything else stock — drops the switch to **195–224 ms** and 146 row bodies, 3/3
runs. `HSplitView` is also `NSSplitView`-backed and is fine, so it is not split views in general.
Excluded by in-app A/B at the same 1250 rows, all still 13–16 s: the floating clear button, the cap
banner, the toolbar, the inspector's `VSplitView`, the table's `idealHeight`/fixed height, favicons
and app icons, every row's content (plain text + one circle), the tail-follow scroll, the selection
(absent / oldest / newest), the sidebar's content (five static rows),
`.navigationSplitViewColumnWidth`, and explicit ideal sizes on the detail column and the root. A
standalone rig reproduced **none** of it — a bare SwiftUI `Table` of 1200 rows stays lazy at ~43
row bodies through all of those variants — so the mechanism behind the container is still
unexplained; what is established is the correlation and the fix. Instruments' SwiftUI instrument
(the tool that would attribute the updates) produced **zero rows** here in five attempts, attach
and launch, at deployment targets 14 and 26 alike: `Trace file had no SwiftUI data`.

## The fix

**`MainView` now uses `HSplitView` — do not swap it back.** The collapse button
`NavigationSplitView` provided is hand-rolled (toolbar `sidebar.left`, `.navigation` placement,
⌃⌘S, `sidebarVisible` state); [DESIGN.md § main-window](../../DESIGN.md#layout-main-window) records the container decision. The
steady-state half was fixed earlier (PR #156): row bodies re-running for unrelated state, the
tail-follow scroll firing on renders that added no row, and a 24 ms `NSWorkspace` icon read inside
a cell.

## Independent re-verification (2026-08-01), two findings the first round missed

1. **The stall needs live traffic with tail-follow to build up**: a cold boot that reloads 2000
   flows from SQLite switches in ~0.7 s, but after just 600 flows arrive live the same switch costs
   **8.7 s** — the quadratic's N is row hosting views *accumulated by scrolling through arriving
   rows*, not the table's row count. That is why the standalone rig (static 1200-row `Table`, stays
   lazy at ~43 bodies) never reproduced it.
2. **What backs the container**, from lldb against the running app: `NavigationSplitView` renders
   as SwiftUI's private `SystemSplitView` representable wrapping a bare **`NSSplitView`**
   (`_NSSplitViewItemViewWrapper` per pane, sidebar behind an
   `NSHostingView<…NavigationPaneModifier…>`) — not `NSSplitViewController`. Since `HSplitView`
   lands on the same `NSSplitView` and is fine, the defect is in `NavigationSplitView`'s private
   glue around the panes, not in split views.

A/B on this exact view, same procedure (600 live flows, then switch): NavigationSplitView 778 ms
(errors) / **8719 ms** (all); HSplitView 117 ms / **143 ms** — 61×. The `sample` stack matches the
original finding frame-for-frame (`_removeViewAndAddToReuse` → `NSView _setWindow:` →
`NSHostingView.viewWillMove(toWindow:)` → KVO `removeObserver` →
`NSKeyValueShareableObservationInfoNSHTHash`, ~5.3 s of a 30 s main-thread sample).
