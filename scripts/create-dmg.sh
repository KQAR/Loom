#!/bin/bash
set -euo pipefail

# Usage: scripts/create-dmg.sh <path-to-Loom.app> <output-dir>
# Packages the exported app into "<output-dir>/Loom.dmg" (unsigned in CI).
APP_PATH="${1:?Usage: create-dmg.sh <Loom.app> <output-dir>}"
OUTPUT_DIR="${2:-.}"

rm -f "$OUTPUT_DIR"/Loom*.dmg

# create-dmg exits 2 when no code-signing identity is found; the DMG is still
# produced, just unsigned — so tolerate exit 2 and fail only on anything else.
set +e
mise exec -- create-dmg "$APP_PATH" "$OUTPUT_DIR" \
  --overwrite \
  --dmg-title="Loom"
EXIT_CODE=$?
set -e

if [ $EXIT_CODE -ne 0 ] && [ $EXIT_CODE -ne 2 ]; then
  exit $EXIT_CODE
fi

# create-dmg names the file "Loom X.Y.Z.dmg"; normalize to "Loom.dmg" so the
# release workflow and appcast reference a stable name.
for f in "$OUTPUT_DIR"/Loom*.dmg; do
  if [ "$f" != "$OUTPUT_DIR/Loom.dmg" ]; then
    mv "$f" "$OUTPUT_DIR/Loom.dmg"
  fi
done
