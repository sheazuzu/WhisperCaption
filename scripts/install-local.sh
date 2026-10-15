#!/usr/bin/env bash
#
# Local-only install for the current user. Builds Release and drops a
# fully-signed .app bundle into /Applications so Launchpad / Spotlight /
# Dock pick it up like any other Mac app.
#
# The installed bundle is called "MeetAndNote 2.0.app" — the version
# number is baked into the file name so Finder makes it obvious which
# build is live. Launchpad/Spotlight still show "MeetAndNote 2.0" because
# that's the CFBundleDisplayName in Info.plist.
#
# IMPORTANT — the on-disk chat history folder (~/Library/Application
# Support/MeetAndNote/) is tied to the app's bundle identifier
# (com.sheazuzu.MeetAndNote), NOT its file name. Renaming the wrapper is
# cosmetic; your existing chats stay put across rebuilds.
#
# Usage:
#   ./scripts/install-local.sh
#
# No arguments. If you want to install multiple variants side by side,
# edit TARGET_NAME below.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PROJECT="$ROOT/MeetAndNote/MeetAndNote.xcodeproj"
SCHEME="MeetAndNote"
CONFIG="Release"

BUILD_DIR="$ROOT/build-local"
PRODUCT_DIR="$BUILD_DIR/Build/Products/$CONFIG"
SRC_APP="$PRODUCT_DIR/MeetAndNote.app"

# Final name shown in Finder. Spaces are fine — macOS handles them,
# and every shell command below quotes paths accordingly.
TARGET_NAME="MeetAndNote 2.0.app"
DEST_APP="/Applications/$TARGET_NAME"
APP_DISPLAY_NAME="${TARGET_NAME%.app}"   # "MeetAndNote 2.0"

# Clean up a stale /Applications/MeetAndNote.app (un-versioned) if it
# somehow got installed by a previous run or by Xcode's archive export.
# It shares the same CFBundleIdentifier as this build, so TCC
# (macOS privacy DB) would see two different cdhashes for the same
# bundle id and the user ends up granting Screen Recording to the
# "wrong" row in System Settings — SCK then keeps returning -3801.
#
# Note: pre-rebrand /Applications/WhisperCaption.app installs use a
# different bundle id (albond.WhisperCaption vs. com.sheazuzu.MeetAndNote),
# so they coexist fine. Delete them manually if you want them gone.
LEGACY_APP="/Applications/MeetAndNote.app"
if [[ -d "$LEGACY_APP" && "$DEST_APP" != "$LEGACY_APP" ]]; then
  echo "==> Found legacy install at $LEGACY_APP"
  echo "    (same bundle id as this build — causes TCC conflicts)"
  echo "    Moving it to Trash …"
  osascript -e 'tell application "MeetAndNote" to quit' 2>/dev/null || true
  sleep 1
  TRASH_NAME="MeetAndNote-legacy-$(date +%Y%m%d-%H%M%S).app"
  mv "$LEGACY_APP" "$HOME/.Trash/$TRASH_NAME" 2>/dev/null || rm -rf "$LEGACY_APP"
  echo "    Done (moved to ~/.Trash/$TRASH_NAME)."
  echo
fi

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
echo "==> Quitting any running copy of \"$APP_DISPLAY_NAME\" …"
osascript -e "tell application \"$APP_DISPLAY_NAME\" to quit" 2>/dev/null || true
# Also quit the vanilla name in case we're transitioning from an older install.
osascript -e 'tell application "MeetAndNote" to quit' 2>/dev/null || true
sleep 1

echo "==> Installing to \"$DEST_APP\" …"
rm -rf "$DEST_APP"
# Copy under the new name. macOS uses the .app wrapper's filename as the
# display name whenever CFBundleDisplayName / CFBundleName aren't set —
# but we DO set CFBundleDisplayName in the pbxproj, so Launchpad shows
# "MeetAndNote 2.0" regardless of the wrapper name.
cp -R "$SRC_APP" "$DEST_APP"

# Re-sign ad-hoc after the rename so Gatekeeper is happy and the embedded
# frameworks still validate. We pin --identifier to the real bundle id so
# TCC (Privacy database) keeps matching this app across rebuilds; without
# that pin every rebuild gets a fresh cdhash and the user has to re-grant
# Screen Recording / Microphone every time.
echo "==> Re-signing (ad-hoc, stable identifier) …"
BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$DEST_APP/Contents/Info.plist" 2>/dev/null || echo 'com.sheazuzu.MeetAndNote')"

# Sign nested bundles first (frameworks + helper tools) — codesign refuses
# to re-sign a container whose contents are unsigned/stale.
find "$DEST_APP/Contents/Frameworks" -type d \( -name '*.framework' -o -name '*.bundle' -o -name '*.dylib' \) -prune -print 2>/dev/null \
  | while read -r nested; do
      codesign --force --sign - --timestamp=none "$nested" >/dev/null 2>&1 || true
    done

# Finally the main .app bundle with a pinned bundle identifier.
codesign --force --sign - \
  --identifier "$BUNDLE_ID" \
  --preserve-metadata=entitlements,requirements \
  --timestamp=none \
  "$DEST_APP" >/dev/null 2>&1 || true

echo "==> Launching …"
open "$DEST_APP"

echo
echo "Done."
echo "  App:        $DEST_APP"
echo "  Bundle ID:  $BUNDLE_ID"
echo "  Launch via: Spotlight / Launchpad → \"$APP_DISPLAY_NAME\""
echo "  Rebuild:    ./scripts/install-local.sh"
echo
echo "If macOS keeps asking for Screen Recording / Microphone even after"
echo "you grant them, the TCC database has stale entries from an older"
echo "build. Run this once, then relaunch the app and grant again:"
echo
echo "    ./scripts/reset-permissions.sh"
echo
echo "First-launch tip (SCStreamError -3801 'The user declined TCCs'):"
echo "  macOS writes new TCC entries lazily — the FIRST ScreenCaptureKit"
echo "  call after you grant permission almost always fails with -3801."
echo "  To get past it:"
echo "    1. Launch the app, press Start, and grant Microphone +"
echo "       Screen Recording when prompted."
echo "    2. Fully quit the app (⌘Q, not just close the window)."
echo "    3. Launch it again — permission now takes effect and Start"
echo "       works on the first try."
