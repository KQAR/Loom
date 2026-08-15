<!-- Loaded only when working under .github/. Workflow-level invariants that used to sit in the
     always-loaded root AGENTS.md. What each job protects is the table in the root § CI. -->

# Workflows — what must stay true

The job inventory and how to read a red run are in the root
[`AGENTS.md` § CI](../AGENTS.md#ci). This file is what a change to a workflow must not break.

**The cache note in § CI is the one to read before touching `actions/cache`**: dependency *sources*
only, never build products, because a DerivedData built under one build graph and reused under
another fails in ways that read exactly like source bugs.

- **CI pins the toolchain; `macos-latest` does not.** *(verified 0.0.24 — `scripts/verify-known-issues.sh`.)* All four workflows set `DEVELOPER_DIR` at the top level (currently `Xcode_26.6`, which is what the last green run on `main` used) and every macOS job runs `scripts/assert-xcode.sh` before building. Without the pin, GitHub refreshing the image changes the Swift compiler and the SDK on a commit that touched neither — and this repo is exposed twice over: the whole graph is on the Swift 6 language mode, and the app opts out of the macOS 26 system design through `UIDesignRequiresCompatibility`, a key Apple documents as temporary (see that entry). Both fail in ways that read as source regressions. The verify step exists because the pin's *own* failure is the illegible one: a `DEVELOPER_DIR` naming a directory the image no longer has surfaces as a missing SDK several steps later, naming nothing. Moving the pin is a deliberate edit with a green run behind it, not a bump. Note the local toolchain is deliberately **not** pinned to match (the maintainer machine was on 26.3 while CI ran 26.6, and both were green); this entry is about CI reproducibility, not about a floor.
