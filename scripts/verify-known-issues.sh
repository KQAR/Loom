#!/bin/bash
# Re-check the AGENTS.md § Known Issues entries that a machine can check.
#
# § Known Issues asks every entry to carry the version it was last *verified* in,
# because these are claims about tooling, an OS and upstream libraries, all of which
# move — and an unstamped entry is indistinguishable from one that stopped being true
# two releases ago. That convention only survives if re-checking is cheap. This is what
# makes it cheap.
#
# It covers the mechanical half only: a pin, a build setting, a symbol that must still
# exist, a script that must still pass. The entries about privileged operations
# (system proxy, pf/QUIC, the helper's launchd record) and about measured OS behaviour
# (the pre-26 design metrics, the NavigationSplitView teardown cost) are **not** here
# and cannot be — they need a real toggle or a profiler. Those entries say so in their
# own text rather than carrying a stamp this script can't back.
#
#   ./scripts/verify-known-issues.sh
#
# Exit non-zero if any check fails. A failure is not automatically a bug: it may be the
# entry that is stale. Read the entry, then fix whichever is wrong.
set -uo pipefail
cd "$(dirname "$0")/.."

pass=0
fail=0

check() { # name, command...
  local name="$1"; shift
  if "$@" >/dev/null 2>&1; then
    printf '  ok    %s\n' "$name"; pass=$((pass + 1))
  else
    printf '  FAIL  %s\n' "$name"; fail=$((fail + 1))
  fi
}

has() { grep -q "$1" "$2"; }

echo "AGENTS.md § Known Issues — mechanical checks"

check "Tuist is pinned to 4.202.5 or later"        has 'tuist = "4\.20[2-9]\|tuist = "4\.[3-9]' mise.toml
check "Swift 6 language mode is the project default" has '"SWIFT_VERSION": "6.0"' Project.swift
check "strict concurrency is complete"             has '"SWIFT_STRICT_CONCURRENCY": "complete"' Project.swift
check "deployment floor is macOS 15 (Project)"     has '"MACOSX_DEPLOYMENT_TARGET": "15.0"' Project.swift
check "deployment floor is macOS 15 (SPM)"         has '\.macOS(\.v15)' Package.swift
check "leaf serials go through makeSerialNumber"   has 'makeSerialNumber' Engine/ProxyCore/Sources/CertificateAuthority.swift
check "the forwarder strips decoded-response headers" \
      has 'sanitizeDecodedResponseHeaders' Engine/ProxyCore/Sources/NIOStreamingForwarder.swift
check "h2 cookie crumbs are coalesced before upstream" \
      has 'coalesceCookieCrumbs' Engine/ProxyCore/Sources/TLSInterceptHandler.swift
check "the SSL scope persists under com.loom.sslScope" \
      has 'com\.loom\.sslScope' Engine/ProxyCore/Sources/InterceptionConfig.swift
check "the CA lives in a file, not the Keychain"   has 'ca-store\.pem' Engine/ProxyCore/Sources/CAStore.swift
check "a pass-through is recorded (TunneledHostLog)" \
      test -f Engine/ProxyCore/Sources/TunneledHostLog.swift
check "MainView is a plain HStack"                 has 'HStack(spacing: 0)' Features/AppFeature/Sources/MainView.swift
check "MainView uses no NavigationSplitView/HSplitView" \
      bash -c '! grep -E "^\s*(NavigationSplitView|HSplitView)\s*[({]" Features/AppFeature/Sources/MainView.swift'
check "the pre-26 design key is still set"         has 'UIDesignRequiresCompatibility' Project.swift
check "release signing is ad-hoc by decision"      has 'CODE_SIGN_IDENTITY="-"' .github/workflows/release.yml
check "Sparkle's public EdDSA key is committed"    has 'SUPublicEDKey' Project.swift
check "NSLock is gone from the repo" \
      bash -c '! grep -rn "= NSLock()" --include="*.swift" App Clients Engine Features Helper SharedModels Tools'
check "the custom SF Symbols still resolve"        python3 Tools/symbol-template/check.py

# Swift Testing runs every test body — sync or async — on the cooperative pool, so a
# blocking wait there parks one of its threads while the engine work it waits for needs
# another (`CapturedExchange.handle` forwards inside `Task {}`). That is the h2 suite's
# CI timeout. `EngineTeardown.swift` § "Why there is no runBlocking here any more" has
# the whole story; the compiler will not catch a relapse, because NIO's
# `@available(*, noasync)` on `wait()` produced no diagnostic for any of the 109 call
# sites this replaced. The two allowed uses wait on event-loop threads, never on a task.
check "no test body blocks on a future" bash -c '
! grep -rn "\.wait()" --include="*.swift" Engine/*/Tests Features/*/Tests Clients/*/Tests SharedModels/Tests \
  | grep -vE ":[0-9]+: *(//|///|\*)" \
  | grep -v "syncShutdownGracefully" \
  | grep -vE "(bind|close)\(.*\)\.wait\(\)|\.close\(\)\.wait\(\)"'
check "the blocking test bridges stay deleted" bash -c '
! grep -rn "func runBlocking\|func awaitFlowBlocking" --include="*.swift" Engine Features Clients SharedModels'

# There was a check here comparing the architecture map's two copies, then one
# validating the single copy that survived. The map itself is gone now (AGENTS.md
# § Layering says why), so there is nothing left to check.

# ProxyCore's warning-free claim. `appintentsmetadataprocessor` prints its own
# `warning:` lines on every build and they are not the compiler's — grepping the raw
# log for "warning:" reads as ~17 warnings and sent one reader chasing nothing. Count
# only lines naming a source file.
echo "  ..    building LoomProxyCore (warning check)"
warnings=$(
  xcodebuild clean build -workspace Loom.xcworkspace -scheme LoomProxyCore \
    -configuration Debug -destination 'platform=macOS' 2>&1 \
    | grep -cE '^/.*\.swift:[0-9]+:[0-9]+: warning:'
)
if [[ "$warnings" == "0" ]]; then
  printf '  ok    LoomProxyCore builds with no compiler warnings\n'; pass=$((pass + 1))
else
  printf '  FAIL  LoomProxyCore builds with %s compiler warning(s)\n' "$warnings"; fail=$((fail + 1))
fi

echo
echo "$pass passed, $fail failed"
[[ "$fail" == "0" ]]
