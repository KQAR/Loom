# "Entitlements file was modified during the build" — two years of bandage, one afternoon of cause

> Moved out of `AGENTS.md` on 2026-08-15, unedited but for the linking sentences. It is a
> **record**, not an instruction: what was tried, what it cost, and why the current shape is
> the shape. The invariant it produced lives in [`AGENTS.md` § Known Issues](../../AGENTS.md#known-issues), which links here —
> read that first; come here when you are about to re-open the question.

## What the entry used to say

> *signing cache stuck after switching branches; delete DerivedData*

That is the bandage, not the diagnosis, and it stood for two releases while
`tuist generate` re-armed the failure on a schedule — the workflow in [§ Build Commands](../../AGENTS.md#build-commands)
*requires* a `generate` after adding a test file.

## The cause, in two halves

**Tuist.** A `.dictionary` entitlement is materialized into `Derived/Entitlements/` by
`GenerateEntitlementsProjectMapper`, which emits an unconditional file side-effect on **every**
`tuist generate` — measured, the content stays byte-identical (same md5) while the mtime
advances every time.

**Xcode.** Its check is mtime-based, so it calls a file whose bytes never changed "modified".

## The deterministic reproduction

Step 2 is a bare `touch` — no Tuist involved:

```bash
xcodebuild build                              # succeeds
touch Derived/Entitlements/Loom.entitlements
xcodebuild build                              # error: Entitlements file "Loom.entitlements"
                                              # was modified during the build
```

It is also **sticky**: once tripped, later builds keep failing with nothing changed until
`~/Library/Developer/Xcode/DerivedData/Loom-*` is deleted. CI never sees it (fresh runner,
empty DerivedData), so this was purely a local tax.

## The fix was to notice the file said nothing

Its only key was `com.apple.security.app-sandbox: false`, and unsandboxed is the **default** —
so the target declares `entitlements: nil` and no file is generated at all.
`codesign -d --entitlements` on the built app shows no `app-sandbox` key, which is the same
state it had before.

Loom does have to stay unsandboxed (0.0.0.0 bind, `networksetup`/`pfctl`, libproc attribution,
`SMAppService`, Authorization Services, writing outside a container), and the reasons live on
the declaration.
