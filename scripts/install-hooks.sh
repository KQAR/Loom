#!/bin/bash
# Point this clone's git hooks at the tracked .githooks/ directory.
#
# core.hooksPath rather than copying into .git/hooks: a copy is a snapshot that
# silently stops matching the tracked hook the moment either changes, and the
# whole reason the hooks are in the repo is that they are reviewed with the code.
# There is nothing to download and no hook manager to keep pinned.
#
# It is per-clone, so a fresh clone runs it once. Nothing in CI depends on it —
# CI runs the same gates directly (.github/workflows/ci.yml, the `docs` job).

set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

git config core.hooksPath .githooks
chmod +x .githooks/*

echo "core.hooksPath = .githooks"
echo "Installed: $(cd .githooks && ls | tr '\n' ' ')"
echo "Bypass a run with: git commit --no-verify"
