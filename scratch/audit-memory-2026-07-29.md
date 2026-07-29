# Memory audit — 2026-07-29

**Counts**: CRITICAL 1 · HIGH 1 · MEDIUM 1 · LOW 1. No previous audit for this area.

Reviewed ~10 resource-owning types; 9 have correct teardown. Zero Combine subscriptions
(the codebase is `AsyncStream` throughout). The one `NotificationCenter` observer
(`RequestTableAutoScroll.swift:49-56`) is matched by a `removeObserver` wired through
`dismantleNSView`. `GlueHandler` and `WebSocketTapHandler` both clear their mutual
`partner` pointer in `handlerRemoved` — those cycles are clean. The #101 fix
(`RequestBodyBridge` aborted from `channelInactive`/`errorCaught`) holds in **both**
`ProxyHandler` and `TLSInterceptHandler`.

---

## CRITICAL — `WebSocketCaptureSink` never finishes when handler installation fails

`Engine/ProxyCore/Sources/WebSocketRelay.swift:71-113` (construction), `:185-188`
(consumer Task), `:218-225` (`finish()`)

The sink's `init` starts an unstored `Task { for await flow in stream { await
store.upsert(flow, force: true) } }`. The only thing that ends it is
`continuation.finish()` inside `sink.finish()`, and the only caller of `sink.finish()` is
`WebSocketTapHandler.channelInactive`.

But `setup()`'s own comment (:82-84) documents that handler removal *can* fail and must
not be swallowed — and that branch (:108-112) closes both channels **without ever having
added either tap handler to a pipeline**:

```swift
case .failure:
    client.close(promise: nil)
    upstream.close(promise: nil)
```

No handler added → no `channelInactive` → no `finish()` → the `AsyncStream` never
terminates → the Task blocks on `for await` forever, retaining the sink, its accumulated
`messages`, and a live `FlowStore` reference. For the life of the process, once per
failed upgrade.

Structurally this is #101 again — a resource whose only teardown path is a callback a
failure branch skips. It presents as a silent leak rather than a crash only because
`AsyncStream.Continuation` doesn't `preconditionFailure` on deinit-without-finish the way
`RequestBodyBridge`'s `Source` does.

**Fix**: call `sink.finish()` in that `.failure` branch.

*(Verified: the failure branch reads exactly as quoted.)*

## HIGH — two unbounded singleton caches

`Features/AppFeature/Sources/FaviconLoader.swift:20` (`icons: [String: NSImage?]`)
`Features/AppFeature/Sources/AppIconLoader.swift:10` (`cache: [String: NSImage]`)

No eviction, no TTL, no cap. One decoded `NSImage` per distinct host / per distinct app
bundle path, forever. CLAUDE.md states "every in-memory collection has an explicit cap",
and everything else honours it — `FlowStore` (2000), `AuditStore` (1000),
`BreakpointStore.pendingContinuations` (64), `ProcessResolver.cache` (`cacheHighWater`).
These two are the exceptions.

Loom is a status-bar app meant to stay resident for days against arbitrary traffic, so
"bounded by how many hosts you visit" is not a bound.

**Fix**: `NSCache` with a `countLimit` — bounded, cost-based eviction, and the idiomatic
AppKit answer for a string-keyed image cache.

## MEDIUM — `RegexCache` and `ProcessResolver.bundleInfo` are uncapped

`SharedModels/Sources/Rules.swift:590-607`, `Engine/ProxyCore/Sources/ProcessResolver.swift:172`

Both key on naturally small domains today (user-authored rule patterns; distinct `.app`
bundles), so the risk is low. Worth noting because `Pattern.matchesLoosely`
(`Rules.swift:613`) also feeds `RegexCache` — if a future caller ever passes a
per-request-varying string as the pattern, this becomes unbounded silently.

**Fix**: the same high-water sweep `ProcessResolver.cache` already has, so "every
collection is capped" is true by construction rather than by luck of domain size.

## LOW — pending flush isn't cancelled on `finish()`

`Engine/ProxyCore/Sources/WebSocketRelay.swift:230-239`

`scheduleFlush()` captures `[weak self]` and the callback guards on `finished`, so this is
**not** a leak. After a flow ends, one no-op timer callback still fires ~100 ms later.
Tidiness only: hold the `Scheduled<Void>` and `.cancel()` it in `finish()`.

---

## Order to fix

1. `sink.finish()` in the `WebSocketRelay.setup()` failure branch.
2. `NSCache` for `FaviconLoader` / `AppIconLoader`.
3. High-water sweep for `RegexCache` / `ProcessResolver.bundleInfo`.

**Instruments check for #1**: force a pipeline-removal failure (typo a handler name, or
race a client disconnect through `setup()`'s `flatMap` chain), run under Allocations with
"Discard events before Mark Generation", and confirm `WebSocketCaptureSink` instance count
climbs per forced failure and never drops.
