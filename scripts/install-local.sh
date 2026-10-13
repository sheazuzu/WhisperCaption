#!/usr/bin/env bash
#
# Local-only install for the current user. Builds Release, renames the
# .app bundle so you can tell it apart from any upstream copy, and drops
# it into /Applications so Launchpad / Spotlight / Dock pick it up like
# a normal Mac app.
#
# IMPORTANT — the on-disk chat history folder (~/Library/Application
# Support/WhisperCaption/) is tied to the app's bundle identifier, NOT
# its file name. We rename the .app wrapper only; CFBundleIdentifier and
# PRODUCT_NAME stay untouched, so your existing chats keep working.
#
# Usage:
#   ./scripts/install-local.sh                 # default suffix "shea"
#   ./scripts/install-local.sh <suffix>        # custom suffix
#
# Examples:
#   ./scripts/install-local.sh                 # ⇒ /Applications/WhisperCaption-shea.app
#   ./scripts/install-local.sh dev             # ⇒ /Applications/WhisperCaption-dev.app

set -euo pipefail

SUFFIX="${1:-shea}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PROJECT="$ROOT/WhisperCaption/WhisperCaption.xcodeproj"
SCHEME="WhisperCaption"
CONFIG="Release"

BUILD_DIR="$ROOT/build-local"
PRODUCT_DIR="$BUILD_DIR/Build/Products/$CONFIG"
SRC_APP="$PRODUCT_DIR/WhisperCaption.app"

TARGET_NAME="WhisperCaption-${SUFFIX}.app"
DEST_APP="/Applications/$TARGET_NAME"

echo "==> Building Release ($CONFIG) …"
xcodebuild \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration "$CONFIG" \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$BUILD_DIR" \
  CODE_SIGN_IDENTITY="-" \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGNING_ALLOWED=YES \
  build \
  | grep -E '(error|warning|FAILED|SUCCEED|\.swift:[0-9]+:[0-9]+:)' || true

if [[ ! -d "$SRC_APP" ]]; then
  echo "ERROR: build output not found at $SRC_APP" >&2
  exit 1
fi

echo
echo "==> Quitting any running copy of $TARGET_NAME …"
osascript -e "tell application \"${TARGET_NAME%.app}\" to quit" 2>/dev/null || true
# Also quit the vanilla name in case we're transitioning from an unsuffixed install.
osascript -e 'tell application "WhisperCaption" to quit' 2>/dev/null || true
sleep 1

echo "==> Installing to $DEST_APP …"
rm -rf "$DEST_APP"
# Copy under the new name. macOS uses the .app wrapper's filename as the
# display name whenever CFBundleDisplayName / CFBundleName aren't set.
cp -R "$SRC_APP" "$DEST_APP"

# Re-sign ad-hoc after the rename so Gatekeeper is happy and the embedded
# frameworks still validate. Non-fatal if codesign isn't available.
echo "==> Re-signing (ad-hoc) …"
codesign --force --deep --sign - "$DEST_APP" >/dev/null 2>&1 || true

echo "==> Launching …"
open "$DEST_APP"

echo
echo "Done."
echo "  App:        $DEST_APP"
echo "  Launch via: Spotlight / Launchpad → \"${TARGET_NAME%.app}\""
echo "  Rebuild:    ./scripts/install-local.sh ${SUFFIX}"
