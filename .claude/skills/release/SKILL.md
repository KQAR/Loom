---
name: release
description: Cut a Loom release and manage Sparkle auto-update — tag-triggered CI (archive → DMG → sign_update → appcast → GitHub release), the EdDSA key pair, and the SPARKLE_EDDSA_KEY repo secret. Use when tagging a version, publishing a build, rotating Sparkle keys, or debugging why auto-update stays dormant.
---

# Releasing Loom (Sparkle auto-update)

Loom self-updates via [Sparkle](https://sparkle-project.org) (same engine as the reference `looper`).
The human sees a footer **"Update"** button in the status-bar panel; the app probes silently once a
day and shows Sparkle's install UI on tap.

## In-app pieces

`UpdaterClient` (TCA dependency) → `UpdaterCoordinator` (owns `SPUStandardUpdaterController`).
`AppFeature` subscribes to availability and drives the panel button. Config lives in `Project.swift`
infoPlist: `SUFeedURL`, `SUPublicEDKey`, `SUEnableAutomaticChecks: false` (we drive cadence
ourselves — the silent probe is self-gated on `com.loom.lastUpdateCheck` in UserDefaults).

## Keys

The EdDSA key pair is managed by Sparkle's `generate_keys` (private key in the login Keychain,
public key committed as `SUPublicEDKey`). Regenerate **only** when rotating:

```
Tuist/.build/artifacts/sparkle/Sparkle/bin/generate_keys        # show/create the key
Tuist/.build/artifacts/sparkle/Sparkle/bin/generate_keys -x key # export private key → CI secret
```

## Release flow

Fully automated by `.github/workflows/release.yml` (triggers on a `v*` tag):

```bash
git tag v0.1.0 && git push origin v0.1.0
```

The workflow: `tuist install/generate` → `xcodebuild archive` (ad-hoc signed) →
`scripts/create-dmg.sh` → `sign_update` + `generate_appcast` → `gh release create` with
`Loom.dmg` + `appcast.xml`.

## Setup status

Repo secret **`SPARKLE_EDDSA_KEY`** (the exported private key) is **set** — the appcast step runs and
auto-update is live (`v0.0.4` published an `appcast.xml` asset). If that secret is ever missing or
rotated badly, the workflow still publishes the DMG but omits the appcast and auto-update goes
dormant with no error — check the release's assets, not just the workflow's green check.

Signing is **ad-hoc by decision** (`CODE_SIGN_IDENTITY="-"`), not a pending task: no Developer ID
certificate is being bought. So a release is never Gatekeeper-clean — a fresh install needs
right-click → Open once — and the EdDSA signature above is what authenticates an update. Don't file
this as a release-blocker; the same decision parks the privileged helper (ROADMAP § M2).

## Sparkle tools

Fetched by `tuist install` into `Tuist/.build/artifacts/sparkle/Sparkle/bin`:
`generate_keys`, `sign_update`, `generate_appcast`.

## Gotcha

Sparkle's transitive framework module must be listed as an explicit `.external(name: "Sparkle")`
dep on any test target that `@testable import`s AppFeature (see `AppFeatureTests`), or the import
fails with "Unable to find module dependency: 'Sparkle'".
