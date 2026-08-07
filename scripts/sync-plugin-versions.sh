#!/bin/bash
# Propagate the app's marketing version into the plugin manifests.
#
# There are four places a version number lives and one of them is the source:
# `Project.swift`'s CFBundleShortVersionString (what the app reports through
# `get_version`). The other three are plugin manifests — Claude's, Cursor's, and the
# one nested inside Cursor's marketplace entry — and they exist because the plugin is
# distributed from this repo but versions independently of a *tag*.
#
# They used to be edited by hand, and were left behind for a whole release: 0.0.14
# through the whole of 0.0.15 before anyone noticed. `VersionFieldParityTests` catches
# that now — but a test that fails is a reminder to do the edit, not a way to do it.
# This is the way to do it.
#
# `release.yml` only tags and builds; it does not bump versions. So the order at
# release time is: edit Project.swift, run this, commit both in the same change.
# The release skill (.claude/skills/release/SKILL.md) says so too.
#
#   ./scripts/sync-plugin-versions.sh          # write the manifests, report what changed
#   ./scripts/sync-plugin-versions.sh --check  # report only, non-zero if any is stale
set -euo pipefail

cd "$(dirname "$0")/.."

check_only=false
[[ "${1:-}" == "--check" ]] && check_only=true

version=$(
  sed -n 's/.*"CFBundleShortVersionString": "\([^"]*\)".*/\1/p' Project.swift | head -1
)
if [[ -z "$version" ]]; then
  echo "error: could not read CFBundleShortVersionString from Project.swift" >&2
  exit 1
fi

# Each manifest, and the jq path of the version field inside it. The nested Cursor
# marketplace entry is the one that gets forgotten, because it doesn't look like a
# version field from the outside.
targets=(
  ".claude-plugin/plugin.json .version"
  ".cursor-plugin/plugin.json .version"
  ".cursor-plugin/marketplace.json .plugins[0].version"
)

stale=0
for target in "${targets[@]}"; do
  read -r file path <<<"$target"
  current=$(jq -r "$path" "$file")
  if [[ "$current" == "$version" ]]; then
    continue
  fi
  stale=1
  if $check_only; then
    echo "stale: $file $path is $current, app is $version"
    continue
  fi
  # `--indent 2` and a trailing newline keep the diff to the one line that changed.
  jq --indent 2 --arg v "$version" "$path = \$v" "$file" > "$file.tmp"
  mv "$file.tmp" "$file"
  echo "updated: $file $path $current -> $version"
done

if $check_only; then
  if (( stale )); then
    echo "run ./scripts/sync-plugin-versions.sh to fix" >&2
    exit 1
  fi
  echo "all plugin manifests are at $version"
fi
