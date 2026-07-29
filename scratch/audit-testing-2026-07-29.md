# Testing audit — 2026-07-29

Scope: all 5 bundles (`ProxyCoreTests`, `MCPServerTests`, `AppFeatureTests`,
`PrivilegedHelperClientTests`, `SharedModelsTests`). No previous audit file for this
area, so no regression check.

**Counts**: CRITICAL 1 · HIGH 3 · MEDIUM 2 · LOW 1

## Shape of what exists

100% Swift Testing — zero `XCTestCase` in first-party tests, so the migration is
genuinely done and there are no XCTest-era findings. Error paths are a real strength:
`FailOpenPathTests` walks every documented fail-open branch (corrupt CA, corrupt rules
file, undecodable SSL scope, unopenable/non-DB SQLite, undecodable rows) and asserts the
*specific* degraded behaviour rather than "didn't crash". Ports are always bound
`port: 0`, upstreams are always stubbed, and no test file holds `static var` state — so
parallel execution has no fixed-port or cross-test-state hazard.

The weakness is concentrated in timing, not coverage.

---

## CRITICAL — busy-spin poll is the likely root cause of today's flake

`Engine/ProxyCore/Tests/BreakpointTests.swift:276-305`
(`cancellingAroundAResolution_leavesNoMarkerBehind`)

The inner wait is `for _ in 0..<2000 where !parked { await Task.yield() }`, run 500 times
— up to a million yields. `Task.yield()` hands off within the same cooperative pool
without giving up wall-clock time, so under CI load the actor-isolated `store.hold(info)`
task can simply fail to be scheduled inside the budget. That is exactly how it failed
today (`try #require(parked)` at :294).

A spin gets *worse* as the machine gets busier, unlike a sleep-based poll.

**Fix**: this file already contains both better patterns — `waitForPending` (:342-349,
5 ms sleep × 200) and `firstParked` (:318-334, which awaits `pendingStream()`). Use the
announcement stream, subscribed before the hold starts:

```swift
var iterator = store.pendingStream().makeAsyncIterator()
let holding = Task { await store.hold(info) }
let announced = await iterator.next()
try #require(announced?.id == info.id, "the exchange never parked")
```

Also: this suite has no `.timeLimit`, and its own comment at :317 acknowledges that a
hang here takes down the whole run instead of failing one test. Worth adding.

## HIGH — `try #require` is not a skip

`Engine/ProxyCore/Tests/EngineLifecycleReentrancyTests.swift:50-53`

The doc comment says "Skipped when the machine has no LAN IPv4 (CI containers, Wi-Fi
off)", but the mechanism is `try #require(LANAddress.primaryIPv4() != nil, …)`, which in
Swift Testing records an issue and **fails**. On the exact environment the author
designed for, this is a hard red.

**Fix**: `@Test(.enabled(if: LANAddress.primaryIPv4() != nil, "needs a LAN IPv4 address"))`
— trait-time evaluation, before the body runs.

*(Verified directly: the code reads as described.)*

## HIGH — fixed-sleep race in `WaitToolTests` (8 sites)

`Engine/MCPServer/Tests/WaitToolTests.swift:101,129,144,168,184,204,257,274`

Every "arrives during the wait" test does:

```swift
async let response = executor.call(name: "wait_for_flow", …)
try await Task.sleep(nanoseconds: 100_000_000)   // hope the executor subscribed
engine.emit(arriving)
```

If the emit beats the subscription the flow is missed and the test falls through to its
`max_seconds` timeout, reporting `timedOut: true` where it expects `false`.

The sibling suite already solved this: `MCPServerTransportTests.swift:36-49` has an
`eventually(_:timeout:_:)` helper and uses it as
`await eventually("the wait to subscribe") { engine.flowSubscriptionsOpened > 0 }`;
`StubEngine.swift:45,51` already exposes that counter. `WaitToolTests` just doesn't use
either.

*(Verified directly: helper and counter both exist; `WaitToolTests` does not reference
them.)*

This is the largest single cluster of flake surface, and it sits on `wait_for_flow` /
`wait_for_pending` — the tools whose whole purpose is "you will not miss an event".

## HIGH — `resolvingAHold_cancelsTheTimeoutWatchdog` remains a wall-clock race

`Engine/ProxyCore/Tests/BreakpointTests.swift:201-224`

Already widened from 50 ms to 500 ms for #116, and CLAUDE.md records that it flaked on
`main` even after. The structure — abort must beat a real timer, then sleep 800 ms *past*
that timer to prove no residual proceed — races wall-clock by construction. A wider
margin lowers the probability; it doesn't change the class.

**Fix**: give the watchdog a test-only completion hook/counter the test can await, so
"the watchdog fired and was a no-op" is observed rather than inferred from a sleep.
Failing that, document the signature of a *real* failure the way
`HTTP2InterceptionTests` documents #99, so a red run is triageable without a re-run.

## MEDIUM — `AbortedRequestBodyTests` poll granularity

`Engine/ProxyCore/Tests/AbortedRequestBodyTests.swift:120-134` — `awaitFailure()` polls
100 × 50 ms and returns nil on timeout; the caller's `#require` turns that into a loud
failure, so it degrades correctly. Only the coarse polling is worth normalizing onto a
continuation resumed when `failure`/`finishedCleanly` is set. Low urgency.

## MEDIUM — h2 stall instrumentation (#99): one observability nit

`Engine/ProxyCore/Tests/HTTP2InterceptionTests.swift:14-153`. Not in scope to fix the
stall. The instrumentation is sound (stage marks, client-flushed vs upstream-consumed
counters, `/usr/bin/sample`, documented `consumed = 65535` signature). Gap: `awaitOrReport`
takes its first sample only after the first 2 s tick, so a very early stall has a coarse
diagnostic window. Optional: take one sample at t=0.

## LOW — `try!` in a fixture helper

`Engine/MCPServer/Tests/MCPServerTransportTests.swift:104` — `try! JSONSerialization.data`
over a test-controlled literal inside a private fixture builder. Benign; noted for sweep
completeness. No action.

---

## Order to fix

1. Spin loop → `pendingStream()` announcement (`BreakpointTests`) — matches today's red.
2. `.enabled(if:)` trait for the LAN-IPv4 test — one line, removes a latent CI trap.
3. Thread `flowSubscriptionsOpened` + `eventually` into `WaitToolTests`' 8 sites.
4. Longer term: promote `eventually()` to a shared test helper so each suite stops
   hand-rolling its own poll budget.
