#!/bin/sh
# Put the privileged helper where `SMAppService.daemon(plistName:)` and launchd look
# for it: the daemon binary in Contents/Library/HelperTools/ (where a privileged helper
# belongs — Contents/MacOS/ is for the app's own executables), its LaunchDaemon plist
# in Contents/Library/LaunchDaemons/. The binary is named after the daemon's label.
#
# Why a script phase rather than a copy-files build phase: the plist has to land in
# a subpath Xcode's canned destinations don't offer, and the binary is another
# target's product. Both must be in place BEFORE the app is signed — build phases
# run ahead of the final CodeSign step, so the app's seal covers them. Moving this
# to a post-*build* action would invalidate the signature and the daemon would
# refuse to load with nothing legible to read.
set -e

HELPER_NAME="com.loom.proxyhelper"
PLIST_NAME="com.loom.proxyhelper.plist"
CONTENTS="${TARGET_BUILD_DIR}/${CONTENTS_FOLDER_PATH}"

if [ ! -x "${BUILT_PRODUCTS_DIR}/${HELPER_NAME}" ]; then
  echo "error: ${HELPER_NAME} was not built — the app target must depend on it." >&2
  exit 1
fi

mkdir -p "${CONTENTS}/Library/HelperTools" "${CONTENTS}/Library/LaunchDaemons"
# `-p` preserves the executable bit; the destination is replaced wholesale so a
# stale daemon from a previous build can never survive into a new bundle.
rm -f "${CONTENTS}/Library/HelperTools/${HELPER_NAME}"
cp -p "${BUILT_PRODUCTS_DIR}/${HELPER_NAME}" "${CONTENTS}/Library/HelperTools/${HELPER_NAME}"
cp -p "${SRCROOT}/Helper/Daemon/${PLIST_NAME}" "${CONTENTS}/Library/LaunchDaemons/${PLIST_NAME}"
