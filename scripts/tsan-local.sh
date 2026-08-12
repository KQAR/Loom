#!/bin/bash
#
# Run `ProxyCoreTests` under ThreadSanitizer locally.
#
# This exists because the obvious command does not work. Xcode 26.3's bundled TSan runtime
# crashes during its own initialization on macOS 26, before a single test runs — xcodebuild
# reports it as `The test runner crashed before establishing connection: xctest at <external
# symbol>`, which names nothing and reads like a project problem.
#
# It is not one. The chain, read bottom-up from a real backtrace:
#
#   dyld runAllInitializersForMain
#    └ libSystem_initializer → _libc_initializer → __guard_setup
#       └ strlcpy  ──► TSan's wrap_strlcpy interceptor
#          └ ScopedInterceptor ctor ──► __tsan::Initialize(thr)     ← TSan starts initializing
#             └ InitializePlatform → CheckAndProtect
#                └ MemoryMappingLayout::Next → __sanitizer::get_dyld_hdr()
#                   └ dyld_shared_cache_iterate_text → dyldFrameworkIntrospectionVtable()
#                      └ dispatch_once ──► TSan's wrap_dispatch_once interceptor
#                         └ __tsan::Release(thr, …) → SlotLock(thr)
#                            └ ldr x10, [x19]   with x19 = thr->slot = 0x0   💥
#
# TSan calls into libdyld while its own ThreadState is half-built; libdyld's introspection
# path uses `dispatch_once`; TSan's `dispatch_once` interceptor is already armed, so control
# re-enters TSan and dereferences a slot that has not been assigned yet. The macOS side of it
# is only the trigger — older dyld did not reach `dispatch_once` from `get_dyld_hdr`.
#
# The fix is in the sanitizer runtime, and this Mac already has a fixed copy: the separately
# installed Command Line Tools ship a *newer* clang than Xcode 26.3 does, and its runtime no
# longer walks the memory map from `CheckAndProtect` (there, `get_dyld_hdr` is first reached
# from `LibIgnore::OnLibraryLoaded`, i.e. after initialization finished). The runtime is
# @rpath-loaded, so pointing DYLD_LIBRARY_PATH at the newer one is enough — nothing is copied,
# patched, or installed.
#
# `TEST_RUNNER_`-prefixed variables are how xcodebuild passes environment into the test
# process; `xctest` is ad-hoc signed without library validation, so dyld does not strip
# DYLD_* from it. That is the same channel `ci.yml` uses for TEST_RUNNER_TSAN_OPTIONS.
#
# Measured 2026-08-12 on macOS 26.5 / Xcode 26.3 / arm64: without the override the runner
# crashes before bootstrapping (exit 65); with it, 464 tests in 78 suites pass in 8.8 s with
# the suppressions file loaded and zero races.
#
# CI does NOT need any of this and deliberately does not do it — the runner is on Xcode 26.6,
# whose bundled runtime is already fixed. Adding a path like this one to `ci.yml` would only
# create a dependency on the runner image's Command Line Tools layout.
#
# One caveat worth knowing before trusting a local result: the instrumented code is built by
# Xcode's clang while the runtime comes from a newer one. The `__tsan_*` ABI is stable in
# practice and this combination runs clean, but CI remains the authority. A race that
# reproduces locally and never on CI should be suspected of being this mismatch first.

set -euo pipefail

cd "$(dirname "$0")/.."
REPO="$PWD"

CLT_CLANG_LIB=""
for dir in /Library/Developer/CommandLineTools/usr/lib/clang/*/lib/darwin; do
    [ -f "$dir/libclang_rt.tsan_osx_dynamic.dylib" ] || continue
    CLT_CLANG_LIB="$dir"
done

if [ -z "$CLT_CLANG_LIB" ]; then
    cat >&2 <<'EOF'
error: no ThreadSanitizer runtime found under /Library/Developer/CommandLineTools.

Xcode's own runtime crashes during initialization on macOS 26 (see the header of this
script), so a run without an override would fail with a message that names nothing.

Install the Command Line Tools:

    xcode-select --install

They are a separate, much smaller download than Xcode, and this script only reads one
dylib out of them — the active toolchain is unaffected.
EOF
    exit 1
fi

# Sanity-check the runtime we picked actually initializes, so a broken one fails here with
# an explanation rather than as an unexplained test-runner crash several minutes later.
PROBE_DIR="$(mktemp -d)"
trap 'rm -rf "$PROBE_DIR"' EXIT
printf 'int main(){return 0;}\n' > "$PROBE_DIR/probe.c"
if ! xcrun clang -fsanitize=thread "$PROBE_DIR/probe.c" -o "$PROBE_DIR/probe" 2>/dev/null; then
    echo "error: could not build the TSan probe with the active toolchain." >&2
    exit 1
fi
if ! DYLD_LIBRARY_PATH="$CLT_CLANG_LIB" "$PROBE_DIR/probe" 2>/dev/null; then
    cat >&2 <<EOF
error: the ThreadSanitizer runtime at
    $CLT_CLANG_LIB
still crashes on an empty main, so it carries the same initialization bug as Xcode's.

Either the Command Line Tools are older than the active Xcode, or this is a new failure.
Reproduce it directly and read the backtrace before assuming it is the known one:

    printf 'int main(){return 0;}\n' > /tmp/t.c
    xcrun clang -fsanitize=thread /tmp/t.c -o /tmp/t && /tmp/t
    lldb --batch -k bt -o run /tmp/t
EOF
    exit 1
fi

echo "TSan runtime: $CLT_CLANG_LIB"

# The suppressions file is staged out of the repo before TSan is pointed at it, and that is
# not tidiness — reading it in place fails. A checkout under a TCC-protected folder
# (`~/Documents`, `~/Desktop`, `~/Downloads`) is unreadable to the test-runner process, and
# TSan reports the refusal as `Checking file existence is not allowed under sandbox` followed
# by `failed to read suppressions file`, then aborts. That surfaces through xcodebuild as the
# *same* `The test runner crashed before establishing connection` line the runtime bug
# produces, so the two are easy to confuse: the discriminator is `abort() called` at the end
# of it (TCC) versus its absence (the init segfault).
SUPPRESSIONS="${TMPDIR:-/tmp}/loom-tsan-suppressions.txt"
cp "$REPO/Tools/tsan/suppressions.txt" "$SUPPRESSIONS"

export TEST_RUNNER_DYLD_LIBRARY_PATH="$CLT_CLANG_LIB"
export TEST_RUNNER_TSAN_OPTIONS="suppressions=$SUPPRESSIONS:print_suppressions=1:verbosity=1"

# Its own DerivedData, for the same reason CI passes one: an instrumented build shares nothing
# useful with the ordinary Debug build, and reusing the default location inherits whatever
# graph that one was last generated against. That is not hypothetical here — the first run of
# this script landed in the default DerivedData and failed with
# `error: Cycle inside CNIOWASI … 'Copy Module Map'`, the same stale-products signature
# AGENTS.md § CI records from the Swift 6 migration, which reads like a source bug and is not.
DERIVED="${LOOM_TSAN_DERIVED_DATA:-$REPO/.build/tsan-DerivedData}"

set -o pipefail
LOG="${TMPDIR:-/tmp}/loom-tsan-local.log"

xcodebuild test \
    -workspace Loom.xcworkspace \
    -scheme ProxyCoreTests \
    -configuration Debug \
    -destination 'platform=macOS' \
    -derivedDataPath "$DERIVED" \
    -enableThreadSanitizer YES \
    CODE_SIGN_ALLOW_ENTITLEMENTS_MODIFICATION=YES \
    "$@" \
    2>&1 | tee "$LOG"

# Same reasoning as ci.yml: a run that never loaded the suppressions file is not a clean run,
# it is an unprotected one, and the two are indistinguishable from the exit status alone.
if grep -q "failed to read suppressions file" "$LOG"; then
    echo "error: TSan could not read $SUPPRESSIONS — this run was unprotected." >&2
    echo "A staged copy outside the repo was still unreadable; check TMPDIR." >&2
    echo "Full log: $LOG" >&2
    exit 1
fi
if ! grep -q "parsed suppression entry 'UnsafeContinuation.resume'" "$LOG"; then
    echo "error: TSan never parsed the suppression entry — this run was unprotected." >&2
    echo "Full log: $LOG" >&2
    exit 1
fi

echo
grep -c "WARNING: ThreadSanitizer" "$LOG" | xargs -I{} echo "ThreadSanitizer reports: {}"
grep -i "Matched .* suppressions" "$LOG" || echo "Suppressions matched: none"
echo "Full log: $LOG"
