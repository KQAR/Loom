#!/bin/bash
# Build the Help Book's search index, in the *built* bundle.
#
# Runs as a post-action on the app target, for the same reason `embed-helper.sh`
# does: it must land before the final CodeSign, or the app's seal won't cover the
# index and Gatekeeper sees a modified bundle.
#
# The index is generated rather than committed on purpose — it is a binary derived
# entirely from the HTML beside it, so a committed copy is a second thing to
# remember to rebuild, and the failure mode of forgetting (Help opens, search finds
# nothing) is quiet.
set -euo pipefail

BOOK="${TARGET_BUILD_DIR}/${CONTENTS_FOLDER_PATH}/Resources/Loom.help"
LPROJ="${BOOK}/Contents/Resources/en.lproj"

if [ ! -d "$LPROJ" ]; then
    echo "error: help book not found at $LPROJ" >&2
    exit 1
fi

# `-I corespotlight` is the index format Help Viewer has used since 10.13; the old
# `lsm` format is still accepted by hiutil and silently ignored by Help Viewer.
# `-a` indexes anchors so a search result can land on a section, `-s en` applies the
# English stopword list.
# The index sits in the .lproj root, where `HPDBookCSIndexPath` names it.
/usr/bin/hiutil -I corespotlight -Cagf "${LPROJ}/Loom.cshelpindex" -s en "$LPROJ"

echo "Indexed help book → ${LPROJ}/Loom.cshelpindex"
