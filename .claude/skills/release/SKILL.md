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

## Bumping the version (do this first, in one commit)

`release.yml` only tags and builds — it does **not** bump anything. Four files carry a version
and one of them is the source:

| | |
|---|---|
| `Project.swift` `CFBundleShortVersionString` | **the source** — what the app reports through `get_version` |
| `Project.swift` `CFBundleVersion` | the build number. **Sparkle compares this one**, so bump it every release |
| `.claude-plugin/plugin.json`, `.cursor-plugin/plugin.json`, `.cursor-plugin/marketplace.json` | the plugin manifests |

Edit the two in `Project.swift` by hand, then propagate:

```bash
./scripts/sync-plugin-versions.sh          # rewrites the three manifests from the app version
./scripts/sync-plugin-versions.sh --check  # report only; non-zero if any is stale
```

Commit all of it in the same `chore(release)` change. The manifests were hand-edited before and
were left behind for a whole release — they sat at 0.0.14 through the whole of 0.0.15.
`VersionFieldParityTests` catches that now, but a failing test is a reminder to do the edit, not a
way to do it; this script is the way.

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
this as a release-blocker.

What ad-hoc signing rules out is narrower than this file used to claim. It does **not** rule out the
privileged helper — that shipped in 0.0.17 and works on an ad-hoc build (measured: registers,
launches as uid 0, serves the system-proxy toggle). What it rules out is *system-domain CA trust*,
because an ad-hoc caller check is forgeable and a root process installing a trusted root CA on a
forgeable caller's word is machine-wide MITM. See [ROADMAP § M2](../../../ROADMAP.md#m2).

## Sparkle tools

Fetched by `tuist install` into `Tuist/.build/artifacts/sparkle/Sparkle/bin`:
`generate_keys`, `sign_update`, `generate_appcast`.

## Gotcha

Sparkle's transitive framework module must be listed as an explicit `.external(name: "Sparkle")`
dep on any test target that `@testable import`s AppFeature (see `AppFeatureTests`), or the import
fails with "Unable to find module dependency: 'Sparkle'".

## Signing and auto-update: the standing decision

- **Auto-update (Sparkle) is armed end-to-end and stays on ad-hoc signing by decision.** *(verified 0.0.24 for the committed config — the key, the ad-hoc identity, the feed URL. Whether a published appcast still installs is not re-checked here; that needs a release.)* `UpdaterClient`/`UpdaterCoordinator` + the panel footer "Update" button work in-app: a silent probe runs at most once a day (self-gated on `com.loom.lastUpdateCheck` in UserDefaults; `SUEnableAutomaticChecks` is deliberately off so the probe stays UI-less), and a user-initiated tap shows Sparkle's install UI. `SUPublicEDKey` in `Project.swift` is a real EdDSA public key (the matching private key is in this machine's login Keychain). The `SPARKLE_EDDSA_KEY` repo secret **is set**, so the `Release` workflow builds → DMGs → signs + generates `appcast.xml` → publishes both to the GitHub release (verified: `v0.0.4` carries an `appcast.xml` asset). The CI archive is ad-hoc (`CODE_SIGN_IDENTITY="-"`) and that is the standing choice, not a gap to close: no Developer ID certificate is being bought. Consequence to state honestly rather than fix — a fresh install is not Gatekeeper-clean (first launch needs the right-click → Open dance), and Sparkle's EdDSA signature, not a Developer ID chain, is what authenticates an update. Same decision parks the privileged helper (see the HTTPS-interception entry). Sparkle's transitive framework module must also be listed as an explicit `.external(name: "Sparkle")` dep on any test target that `@testable import`s AppFeature (see `AppFeatureTests`).
