# TSan on macOS 26: a runtime bug, not an OS limitation

*Measured 2026-08-12 — macOS 26.5 (25F71), Xcode 26.3, arm64.*

For several releases `AGENTS.md` carried this, in two places:

> **Can't be reproduced locally on macOS 26**: TSan's runtime segfaults during its own init
> there (an empty `int main(){}` reproduces it)

The reproduction is real. The attribution is wrong, and the cost of the wrong half was that
`ProxyCoreTests` could only be run under ThreadSanitizer by pushing to CI — a minutes-long
round trip on the one check that covers the `@unchecked Sendable` channel handlers.

## The tell that was in plain sight

CI's TSan job is green, and CI runs:

```
Image: macos-26-arm64  (20260728.0273)
Xcode 26.6
```

Same OS major, same architecture, same job. So "macOS 26" cannot be the discriminator. The
only variable left is the toolchain: Xcode 26.3 ships clang 17.0.0, the runner has 26.6.

This is the same shape as the privileged-helper mistake recorded in
[`privileged-helper.md`](privileged-helper.md) — **a claim about what the platform refuses is
a measurement, not a deduction** — arrived at from the other direction. There the claim was
never run; here it *was* run, and the conclusion drawn from it was too broad.

## The root cause

`lldb --batch -k bt -o run` on a two-line C file, built `-fsanitize=thread`:

```
EXC_BAD_ACCESS (code=1, address=0x0)

  #0  __tsan::SlotLock(__tsan::ThreadState*) + 28      ldr x10, [x19]   x19 = 0x0
  #1  __tsan::Release(__tsan::ThreadState*, ...)
  #2  wrap_dispatch_once
  #3  libdyld.dylib`dyldFrameworkIntrospectionVtable()
  #4  libdyld.dylib`dyld_shared_cache_iterate_text
  #5  __sanitizer::get_dyld_hdr()
  #6  __sanitizer::MemoryMappingLayout::Next(...)
  #7  __tsan::CheckAndProtect(bool, bool, bool)
  #8  __tsan::InitializePlatform()
  #9  __tsan::Initialize(__tsan::ThreadState*)
  #10 __tsan::ScopedInterceptor::ScopedInterceptor(...)
  #11 wrap_strlcpy
  #12 libsystem_c.dylib`__guard_setup
  #13 libsystem_c.dylib`_libc_initializer
  #14 libSystem.B.dylib`libSystem_initializer
  #15 dyld`…findAndRunAllInitializers…
```

Read it bottom-up. dyld runs the image initializers; `libSystem`'s stack-guard setup calls
`strlcpy`; TSan's interceptor fires and, finding TSan uninitialized, calls `__tsan::Initialize`.
Platform init then asks for the memory map, which on current dyld reaches
`dyld_shared_cache_iterate_text` — an introspection API that uses `dispatch_once` internally.
TSan intercepts `dispatch_once`. Control re-enters TSan, which reaches for `thr->slot` on a
`ThreadState` whose initialization is still on the stack below. `x19 = 0x0000000000000000`.

**It is a re-entrancy bug in the sanitizer runtime.** The OS's contribution is only that
current dyld reaches `dispatch_once` from `get_dyld_hdr`, which older dyld did not.

## How the newer runtime fixes it

The same breakpoints against clang 21's runtime show the entry path unchanged —
`__guard_setup → strlcpy → Initialize` is identical — but the *first* call to `get_dyld_hdr`
now comes from somewhere else entirely:

```
  #0  __sanitizer::get_dyld_hdr()
  #1  __sanitizer::MemoryMappingLayout::Next(...)
  #2  __sanitizer::MemoryMappingLayout::DumpListOfModules(...)
  #3  __sanitizer::MemoryMappingLayout::MemoryMappingLayout(bool)
  #4  __sanitizer::ListOfModules::init()
  #5  __sanitizer::LibIgnore::OnLibraryLoaded(char const*)
```

i.e. after initialization has finished, not from inside `CheckAndProtect`. The fix removed
the window rather than null-checking `SlotLock`. Both runtimes still import
`dyld_shared_cache_iterate_text`, so it is the call site that moved, not the API that went
away.

## The lever, and why it needs no download

The runtime is `@rpath`-loaded, and a fixed copy is already on a normal developer machine:
the separately installed **Command Line Tools** carry a newer clang than Xcode does
(21.0.0 against Xcode 26.3's 17.0.0). Pointing `DYLD_LIBRARY_PATH` at it is enough — nothing
is copied into `Xcode.app`, nothing is re-signed, no `sudo`.

| run | result |
|---|---|
| Xcode 26.3 clang, empty `main` | `exit=139` (SIGSEGV) |
| same binary, `DYLD_LIBRARY_PATH` → CLT runtime | `exit=0` |
| Xcode 26.3 `swiftc -sanitize=thread` | `exit=139` |
| same binary + CLT runtime | `exit=0` |

Seven `TSAN_OPTIONS` variants (`detect_deadlocks`, `history_size`, `flush_memory_ms`,
`die_after_fork`, `ignore_noninstrumented_modules`, `verbosity`) change nothing: the crash
precedes options parsing, which is why `verbosity=1` prints nothing at all.

For `xcodebuild`, the channel is `TEST_RUNNER_DYLD_LIBRARY_PATH` — the same prefix mechanism
`ci.yml` already uses for `TEST_RUNNER_TSAN_OPTIONS`. It works because `xctest` is ad-hoc
signed with no library-validation flag and `get-task-allow`, so dyld does not strip `DYLD_*`
from its environment. That was checked with `codesign -dvvv` before relying on it, since the
failure mode would otherwise have been another silent no-op of exactly the kind
[`tsan-continuation-race.md`](tsan-continuation-race.md) is about.

A/B on the real suite, same build products, one variable:

| run | result |
|---|---|
| with `TEST_RUNNER_DYLD_LIBRARY_PATH` | `** TEST SUCCEEDED **` — 464 tests, 78 suites, 8.8 s, **0 races**, suppressions loaded and parsed |
| without | `** TEST FAILED **`, exit 65 — `The test runner crashed before establishing connection: xctest at <external symbol>` |

## Two failure signatures the script pre-empts

Both were hit while writing `scripts/tsan-local.sh`, and neither names its own cause. The
second one cost more than the runtime bug it was mistaken for, because it produces the *same*
xcodebuild line.

**`error: Cycle inside CNIOWASI … 'Copy Module Map'`** — the run landed in the default
DerivedData, which was generated against a different build graph. This is the same
stale-products signature AGENTS.md § CI records from the Swift 6 migration, and it reads
exactly like a source bug. The script uses its own `-derivedDataPath`
(`.build/tsan-DerivedData`, overridable via `LOOM_TSAN_DERIVED_DATA`), which is also right on
its own terms: an instrumented build shares nothing useful with the ordinary Debug one.

**`Checking file existence is not allowed under sandbox` → `failed to read suppressions file`
→ `abort()`.** TSan dies when it cannot read the suppressions file, and xcodebuild reports
that death as `The test runner crashed before establishing connection: xctest at <external
symbol>` — byte-identical to the runtime bug above, except for a trailing `libsystem_c.dylib:
abort() called`. **That trailing clause is the discriminator**; without it the two are the
same line.

The suppressions file lives at `Tools/tsan/suppressions.txt`, i.e. under `~/Documents`, which
is TCC-protected. What was actually measured, and it is stranger than "the path is
unreadable":

| invocation | reading from the repo path |
|---|---|
| the identical `xcodebuild` line typed directly into the shell (zsh or `bash -c`) | reads it, 4/4 |
| the same line from `scripts/tsan-local.sh` | `failed to read`, 5/5 |
| either, reading a copy staged into `$TMPDIR` | reads it, 2/2 |

The environments are identical — diffed variable by variable, the only differences are the
two `TEST_RUNNER_*` exports that are the point, `SHLVL`, and `__CF_USER_TEXT_ENCODING`. So
this is not a permission on the file; it is TCC attributing the access to a different
responsible process depending on how the test runner was launched. **The exact rule was not
pinned** — what was pinned is that staging the file out of the protected folder makes it
deterministic, which is what the script does. It also asserts the entry was *parsed*, not
merely that a read was attempted: an unprotected run and a clean run are indistinguishable
from the exit status, which is the whole subject of
[`tsan-continuation-race.md`](tsan-continuation-race.md).

A checkout outside `~/Documents` / `~/Desktop` / `~/Downloads` presumably never sees this.
That was not tested, and the staging costs nothing either way.

## What is deliberately not done

**CI is not changed.** Its toolchain already carries the fixed runtime; adding a Command Line
Tools path there would create a dependency on the runner image's layout in exchange for
nothing.

**The local result is not the authority.** The instrumented code is emitted by Xcode's clang
while the runtime comes from a newer one. The `__tsan_*` ABI is stable in practice and this
combination runs clean, but the mismatch is real: a race that reproduces locally and never on
CI should be suspected of being the mismatch before it is believed.

## What this gives the upstream report

[`swiftlang/swift#57803`](https://github.com/swiftlang/swift/issues/57803) (SR-15498) was
closed in 2023 as no longer reproducing. The filing tracked in issue #231 can now say more
than "it happens again": there is a deterministic ten-line reproduction, a full backtrace
naming the re-entrant call, a version window (broken in clang 17.0.0 / Xcode 26.3, fixed by
clang 21.0.0), and the shape of the fix (the memory-map walk left `CheckAndProtect`).

---

## Later note (0.0.27): the local run stopped working again, for a different reason

Re-run on this machine and `scripts/tsan-local.sh` fails before a single line of Loom code
runs — at the commit that produced this record too, so it is not a regression in whatever is
being tested:

```
Failed to create a bundle instance representing … ProxyCoreTests.xctest
```

`dlopen` explains it as `Library not loaded: @rpath/LoomProxyCore.framework` — a bundle-load
failure, not a race and not the init segfault above. Without the runtime override the runner
still dies with the documented init-segfault signature, so the override itself is still doing
its job. The suspect is that the separately installed Command Line Tools have moved to clang
21.0.0 since this record was written, i.e. the very version window that fixed the original bug.

Not chased further, because the CI job is unaffected and is the one that gates. Whoever needs a
local run next: start there, and re-stamp the `AGENTS.md` entry.
