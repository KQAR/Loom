# Finishing the Swift 6 migration: four shapes, and 25 warnings that were never what they said

> Moved out of `AGENTS.md` on 2026-08-15, unedited but for the linking sentences. It is a
> **record**, not an instruction: what was tried, what it cost, and why the current shape is
> the shape. The invariants it produced live in [`AGENTS.md` § Known Issues](../../AGENTS.md#known-issues), which links here —
> read that first; come here when you are about to re-open the question.

## The three test bundles that were deliberately on Swift 5 (0.0.16)

The old reason — "a red test is a red test rather than a migration artifact" — expired once
the modules were all on 6. The migration cost was small and worth naming, because the same four
shapes will recur:

1. `syncShutdownGracefully` and `NSLock.lock()` are `@available(*, noasync)`, and a `defer` in
   an `async` test body *inherits* the async context, so those became errors.
   `shutdownBlocking(_:)` in `EngineTeardown.swift` is the documented synchronous wrapper
   (blocking is what teardown wants; a `Task` there is the late-teardown defect that file
   exists to prevent), and the locks moved to `withLock`.
2. The `async → sync` bridges each needed `@Sendable` on the body closure they hand to a
   `Task`.
3. `@MainActor` test suites calling nonisolated `MCPToolExecutor.call` had to mark their
   `[String: Any]` argument builders `sending`, which states the truth (freshly built, never
   kept) rather than silencing anything.
4. One `position: .after(tls)` was a *second* use of a non-`Sendable` handler already given to
   the pipeline — reordered rather than annotated.

## The 25 warnings, and why the framing cost more than the fix

For as long as ProxyCore had been on Swift 6 it carried ~25 warnings, and both `AGENTS.md` and
`Engine/ProxyCore/CLAUDE.md` filed them under "needs the `NIOAsyncChannel` rework, not
scheduled".

**That framing was wrong and it cost real time.** The warnings were never about the handlers,
only about *where handlers were constructed*, and every one of them went away without changing
a single handler type — two idioms, both now documented at the sites in
[`Engine/ProxyCore/CLAUDE.md` § Sendable escape hatches](../../Engine/ProxyCore/CLAUDE.md#sendable-escape-hatches-what-each-kind-actually-promises):

- construct handlers **inside** `channel.eventLoop.makeCompletedFuture { … }` and add them via
  `channel.pipeline.syncOperations` — that body is not `@Sendable`, unlike `flatMap`'s, so
  nothing crosses;
- reach for `eventLoop.assumeIsolated()` / `future.assumeIsolated()` when a callback captures
  `ChannelHandlerContext`, which swaps an assumption these handlers already depend on for a
  `preconditionInEventLoop()` that checks it.

The lesson to carry: **a warning bundled into a big unscheduled rework deserves re-reading
before it is inherited** — the bundle here was the expensive part, not the warnings.
`@unchecked Sendable` on the handler types is genuinely the `NIOAsyncChannel` job and genuinely
still unscheduled; that much was right.
