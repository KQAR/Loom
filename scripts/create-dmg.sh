#!/bin/bash
set -euo pipefail

# Usage: scripts/create-dmg.sh <path-to-Loom.app> <output-dir>
# Builds "<output-dir>/Loom.dmg" with hdiutil — macOS built-in, no third-party
# or native deps. (The npm `create-dmg` pulls node-gyp addons like macos-alias
# that don't prebuild on CI's Node, failing with MODULE_NOT_FOUND.)
APP_PATH="${1:?Usage: create-dmg.sh <Loom.app> <output-dir>}"
OUTPUT_DIR="${2:-.}"
DMG="$OUTPUT_DIR/Loom.dmg"

rm -f "$DMG"

# Stage the app plus a drag-to-install /Applications symlink.
STAGING="$(mktemp -d)"
trap 'rm -rf "$STAGING"' EXIT
cp -R "$APP_PATH" "$STAGING/"
ln -s /Applications "$STAGING/Applications"

hdiutil create \
  -volname "Loom" \
  -srcfolder "$STAGING" \
  -fs HFS+ \
  -format UDZO \
  -ov \
  "$DMG"

echo "Created $DMG"
