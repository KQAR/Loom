# TSan continuation reproducer

Ten lines that produce the ThreadSanitizer report which intermittently reddens the
`Thread Sanitizer (ProxyCore)` CI job — with **no SwiftNIO and no Loom code involved**.

```bash
swiftc -parse-as-library -sanitize=thread main.swift -o repro && ./repro
```

## Why it's here

The report Loom sees is:

```
WARNING: ThreadSanitizer: data race
  Write of size 8 ... suspend resume partial function for withUnsafeThrowingContinuation
  Previous read of size 8 ... UnsafeContinuation.resume(returning:)
      in NIOCore.EventLoopFuture.get()
```

Every racing frame belongs to NIOCore or the Swift runtime; none belong to Loom. The
same signature is upstream as [swiftlang/swift#57803](https://github.com/swiftlang/swift/issues/57803)
(SR-15498), closed in 2023 as no longer reproducing — its reproducer is the file next
to this README.

What Loom's own measurements add (via `.github/workflows/tsan-reverse-proxy-hunt.yml`):

| selection | iterations | result |
|---|---|---|
| `ReverseProxyTests` only | 25 | clean |
| one reverse-proxy test | 25 | clean |
| whole `ProxyCoreTests` | 25 | hit at iteration 2 |
| whole suite, `ReverseProxyTests` **excluded** | 25 | hit at iteration 8 |
| same, after the event-loop-group leak fix | 25 | hit at iteration 2 |

The fourth row is the one that matters: it reproduces with the suite that first exposed
it removed entirely. The rate tracks how many engines — and therefore how many
`EventLoopFuture.get()` bridges — a single process runs, not which tests are selected.

## What it is not

Not a licence to ignore a red TSan job. The three defects found while chasing this were
all real, and none of them were this:

- a detached-`Task` test teardown that ran during the *next* test (#210);
- `stopAll()` iterating `channels.keys` while `stop(id:)` removed from it — undefined
  behaviour on every engine stop (#212);
- `ProxyEngine` never shutting down its `MultiThreadedEventLoopGroup`, leaking two
  threads per engine (#213).

Read the report before dismissing it: if a racing frame names a Loom symbol, it is ours.
