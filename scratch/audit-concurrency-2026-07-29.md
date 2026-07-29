# Concurrency audit — 2026-07-29

**Counts**: CRITICAL 0 · HIGH 2 · MEDIUM 1. Plus 3 assumptions explicitly verified as
safe. No previous audit for this area.

The two-regime split is respected and is not reported as a defect: `App`/`Features`/
`Clients` under Swift 6 strict, `ProxyCore`/`MCPServer`/`SystemProxyClient` under Swift 5
with `@unchecked Sendable` handlers. All four actors (`ProxyEngine`, `FlowStore`,
`AuditStore`, `FlowBatchBuffer`, `WaitCollector`) are internally synchronous — no
check-then-act reentrancy bugs found; `ProxyEngine` sets its `running`/`stopping`/
`startingPhoneOnboarding` flags before the first `await`, which is the right shape.
Every `AsyncThrowingStream` producer in the forward chain wires
`onTermination = { task.cancel() }`.

The findings are both in code that is *off* the actor by design, and neither is a data
race — which is why the TSan job is green and still missed them.

---

## HIGH — rule / SSL-scope persistence can regress to a stale snapshot

`Engine/ProxyCore/Sources/RulesConfig.swift:91-97`
`Engine/ProxyCore/Sources/InterceptionConfig.swift:35-40`

```swift
private func mutate(_ body: (inout RulesState) -> Void) {
    lock.lock()
    body(&state)
    let updated = state
    lock.unlock()
    if let fileURL { Self.persist(updated, to: fileURL) }   // outside the lock
}
```

In-memory state is properly serialized. The **write to disk is not**: it runs after
unlock, on whichever thread called in, with no ordering between callers. Two overlapping
MCP write tools (`set_rule` then `delete_rule` moments apart — each tool call is its own
Task, so this interleaving is real) take snapshots in order A→B, but nothing stops A's
`persist` from completing *after* B's. Disk ends up holding A while memory holds B. No
error is logged; the divergence only surfaces on the next launch, as a deleted rule
reappearing or an added one vanishing.

`InterceptionConfig.update` has the identical shape for the SSL scope, which is the
setting CLAUDE.md specifically notes must survive relaunch or all HTTPS goes blind-tunneled.

`FlowPersistence` and `AuditPersistence` already avoid exactly this by funneling writes
through a private serial `DispatchQueue`. These two persist inline instead.

**Fix**: persist while still holding the lock, or serialize `persist` through a private
queue like the two SQLite stores. Add a test that races two mutations and asserts the file
matches the logically-later state.

*(Verified: both functions read exactly as quoted.)*

## HIGH — blocking libproc scan runs on the cooperative thread pool

`Engine/ProxyCore/Sources/CapturedExchange.swift:84-98,102-118` (call sites)
`Engine/ProxyCore/Sources/ProcessResolver.swift:126-163` (the scan)

`ProcessResolver.resolve`'s doc comment says it must run "off the event loop… from the
async forwarding task". That half is honoured — it's called inside a `Task {}`, not from
`channelRead`. But the scan itself is *synchronous and blocking*, so it blocks a worker on
Swift's global concurrent executor, which is sized to core count.

The cache TTL is 2 s, so a connection burst produces several concurrent misses, each
pinning a pool worker for the duration of a full pid/fd sweep — stalling unrelated async
work process-wide (other exchanges, actor hops, MCP calls). Not a race, so TSan can't see
it; it is a scheduling hazard, and this repo treats performance as a hard requirement.

**Fix**: bridge the scan onto a dedicated serial queue via `withCheckedContinuation` — the
manual equivalent of `@concurrent`, which isn't available in Swift 5 mode.

## MEDIUM — `MCPHTTPHandler.respond` captures `self` strongly

`Engine/MCPServer/Sources/MCPServer.swift:312-323`

Not a leak — bounded by the 60 s wait cap on a connection-scoped object. But it pins the
handler and its channel for the rest of a long blocking wait even after the client hangs
up, because `Task.isCancelled` is only consulted after `await dispatcher.handle` returns.
Also inconsistent with the `[weak self]` discipline used elsewhere (e.g.
`FaviconLoader.swift:51`).

**Fix**: `[weak self]`.

---

## Assumptions checked and confirmed safe

- **`WebSocketCaptureSink`'s "one shared event loop, so no lock" claim is TRUE.**
  `WebSocketRelay.start` bootstraps upstream with `group: clientChannel.eventLoop`; a lone
  `EventLoop` as the bootstrap group guarantees the new channel lands on that exact loop.
  So `record` / `scheduleFlush` / `finish` are serialized by one loop no matter which side
  goes inactive first, and the `finished` guard makes the double-`channelInactive` case
  idempotent. The 100 ms coalescing flush added in #121 is sound as written.
- **`NIOStreamingForwarder`'s double-finish paths are benign** —
  `AsyncThrowingStream.Continuation.finish`/`yield` are thread-safe and
  idempotent-after-terminal, and `ChannelBox`'s lock handles the connect-after-close race.
- **`wait_for_flow` / `wait_for_pending` cancellation really does unblock the child task** —
  `AsyncStream` iteration observes consumer cancellation and resumes via
  `onTermination(.cancelled)`, so `withTaskGroup`'s cancel-then-await-all terminates
  promptly rather than parking forever.

## Order to fix

1. Persist-outside-lock in `RulesConfig` / `InterceptionConfig` — silent data loss across
   relaunch, cheap fix.
2. `ProcessResolver`'s blocking scan onto a dedicated queue.
3. `[weak self]` in `MCPHTTPHandler.respond`.
