#!/usr/bin/env bash
#
# Fail loudly when the pinned Xcode is not on this runner, and print the
# toolchain every job actually compiled with.
#
# Every macOS job sets `DEVELOPER_DIR` at the workflow level rather than taking
# whatever `macos-latest` happens to default to. Without the pin, GitHub
# refreshing the image silently changes the compiler underneath a repo whose
# whole graph is on the Swift 6 language mode and whose app opts out of the
# macOS 26 system design through `UIDesignRequiresCompatibility` — a key Apple
# documents as temporary. Both of those fail in ways that read as source
# regressions, on a commit that changed neither.
#
# Without this check the pin's own failure mode is the illegible one: a
# `DEVELOPER_DIR` naming a directory that no longer exists makes xcodebuild
# report a missing SDK or an unusable toolchain, several steps later and with
# nothing naming the pin. So the pin is verified before anything is built, and
# the error lists what the runner does have — which is the version to move the
# pin to.
set -euo pipefail

: "${DEVELOPER_DIR:?DEVELOPER_DIR is unset — the workflow must pin an Xcode}"

if [ ! -d "$DEVELOPER_DIR" ]; then
  echo "::error::Pinned Xcode is not installed on this runner: $DEVELOPER_DIR"
  echo "Available on the image:"
  ls -d /Applications/Xcode*.app 2>/dev/null || echo "  (none found under /Applications)"
  echo
  echo "Update DEVELOPER_DIR in the workflow's top-level env: block to one of the above."
  exit 1
fi

xcodebuild -version
swift --version
