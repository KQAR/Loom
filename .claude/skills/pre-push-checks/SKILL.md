---
name: pre-push-checks
description: Use before pushing a Loom branch, opening or updating a PR, or claiming "tests pass" — selects the smallest set of checks that actually covers the outgoing diff instead of reflexively running all five test bundles, and names the two traps that make a green local run mean nothing.
---

# Loom pre-push checks

Guidance, not a script. Pick the narrowest evidence that would **fail for this diff's
regression**, run it once, and report only what you ran. CI owns the exhaustive matrix —
the whole Tuist graph, all five bundles, TSan, the SPM library graph — and it runs on
every push regardless of what you did locally. Duplicating it before every commit costs
ten minutes a time and catches nothing CI wouldn't.

## Two traps first — a green local run can mean nothing

**1. A new test file is not in the target until `tuist generate` runs.** `Project.swift`
lists sources by glob and the glob is expanded at *generate* time into the `.xcodeproj`.
Add a test file, run `xcodebuild test`, and you get `** TEST SUCCEEDED **` having executed
zero of it. So: after adding or moving any test file, `tuist generate --no-open` **before**
testing, and treat `scripts/assert-tests-ran.sh <result-bundle> <bundles…>` as the pass
condition rather than xcodebuild's exit code.

**2. `-workspace` is required.** With only `-scheme`, xcodebuild picks the wrong project
and fails to resolve SPM modules (`Unable to find module dependency:
'ComposableArchitecture'`) — which reads as a dependency problem and is not one.

## Inspect the outgoing change

```sh
git status --short --branch
git diff --name-only origin/main...HEAD   # committed scope
git diff --name-only                      # plus anything unstaged
```

Then pick from the table by what the diff *reaches*, not by which directory it sits in.

| The diff touches | Run |
|---|---|
| `Engine/ProxyCore/**` | `ProxyCoreTests` — and read § Concurrency before touching a channel handler |
| `Engine/MCPServer/**`, any tool schema, any render DTO | `MCPServerTests` (`RenderParityTests` is the census that fails when a model grows a field the agent can't see) |
| `SharedModels/**` | `SharedModelsTests` **and** the bundles of every consumer the changed type reaches — a value type here is the one thing all five see |
| `Features/AppFeature/**` | `AppFeatureTests` |
| `Clients/PrivilegedHelperClient/**`, `Helper/**` | `PrivilegedHelperClientTests` — note the privileged paths themselves (pf, `networksetup`, the launchd record) are unreachable from any test and need one real toggle |
| `Project.swift`, `Tuist/Package.swift`, target deps, embed steps | `tuist install && tuist generate --no-open` and a build; the plugin-version parity test lives in `SharedModelsTests` |
| root `Package.swift`, anything under the SPM library products | `swift build && swift test` — this graph resolves without Tuist and rots silently otherwise |
| any `*.md`, `scripts/doc-budgets.json` | `scripts/verify-doc-budgets.py`, `scripts/verify-md-links.py` |
| `docs/decisions/**` | the two above plus `scripts/verify-decision-records.py` |
| an entry in § Known Issues you re-verified | `scripts/verify-known-issues.sh`, and move the entry's version stamp |
| a custom SF Symbol or `Tools/symbol-template/**` | `python3 Tools/symbol-template/check.py` — the only check that catches a symbol which compiles clean and is `nil` at runtime |

One bundle, the usual case:

```sh
tuist generate --no-open   # only if a test file was added or moved
xcodebuild test -workspace Loom.xcworkspace -scheme Loom-Workspace \
  -destination 'platform=macOS' -only-testing:ProxyCoreTests \
  -resultBundlePath /tmp/Tests.xcresult
scripts/assert-tests-ran.sh /tmp/Tests.xcresult ProxyCoreTests
```

The `.githooks/pre-commit` hook already runs the whitespace check and the documentation
gates for the files they read; do not run those again by hand before pushing.

## When the full local rehearsal is right

Only three cases: the user asked for it, you are diagnosing a CI failure, or the change is
genuinely repository-wide (a `SharedModels` type every layer reads, a Swift-version or
build-settings change, a Tuist bump). Then it is the § Build Commands sequence with all five
bundles named to `assert-tests-ran.sh`.

TSan is **not** part of a normal pre-push. It is a CI job; `scripts/tsan-local.sh` exists but
currently fails to load the test bundle on this machine ([ProxyCore § Known issues
(engine-scoped)](../../../Engine/ProxyCore/CLAUDE.md#known-issues-engine-scoped)), and a local-only
TSan failure is an ABI-mismatch suspect before it is a Loom bug.

## Report honestly

Say which commands you ran and what they covered. A check you did not run is not evidence,
and "tests pass" without a bundle name is not a claim anyone can check. If something failed,
quote the shortest decisive line rather than the log. Do not push past a failing relevant
check hoping CI differs — but do read a red CI run before attributing it to your branch
([`docs/decisions/ci-red-run-triage.md`](../../../docs/decisions/ci-red-run-triage.md) has
the four things it can be, only one of which is a regression).

## The one build failure that survives a clean rebuild

- **Loom declares no entitlements at all, and a new one must be `.file(path:)` — never `.dictionary`.** *(verified 0.0.20.)* A `.dictionary` entitlement is re-materialized by every `tuist generate` with identical bytes and a fresh mtime, and Xcode's check is mtime-based, so the build fails with `error: Entitlements file "Loom.entitlements" was modified during the build` — **stickily**, until `~/Library/Developer/Xcode/DerivedData/Loom-*` is deleted. CI never sees it (fresh runner); the workflow in [§ Build Commands](../../../AGENTS.md#build-commands) re-arms it locally on every added test file. The target now declares `entitlements: nil`, because the file's only key was `com.apple.security.app-sandbox: false` and unsandboxed is the default; Loom does have to stay unsandboxed, and the reasons live on the declaration. The two-release misdiagnosis ("signing cache stuck; delete DerivedData"), the three-step reproduction and the `codesign` check that the state is unchanged: [`docs/decisions/entitlements-modified-during-build.md`](../../../docs/decisions/entitlements-modified-during-build.md).
