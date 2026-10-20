#!/usr/bin/env bash
#
# Local-only install for the current user. Builds Release and drops a
# fully-signed .app bundle into /Applications so Launchpad / Spotlight /
# Dock pick it up like any other Mac app.
#
# Signing modes:
#   • If MeetAndNote/Local.xcconfig has a non-empty DEVELOPMENT_TEAM and
#     a matching "Apple Development: … (TEAMID)" cert is in your login
#     Keychain, we sign with that identity. TCC permissions then key on
#     (TeamID, BundleID) and SURVIVE REBUILDS — grant once, never again.
#   • Otherwise we fall back to ad-hoc signing + auto `tccutil reset` and
#     tell the user to walk through the "two-round" first-launch dance.
#
# The on-disk chat history folder (~/Library/Application Support/MeetAndNote/)
# is tied to CFBundleIdentifier, NOT the .app filename, so renaming the
# wrapper never loses history.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PROJECT="$ROOT/MeetAndNote/MeetAndNote.xcodeproj"
SCHEME="MeetAndNote"
CONFIG="Debug"

BUILD_DIR="$ROOT/build-local"
PRODUCT_DIR="$BUILD_DIR/Build/Products/$CONFIG"
SRC_APP="$PRODUCT_DIR/MeetAndNote.app"

TARGET_NAME="MeetAndNote 2.0.app"
DEST_APP="/Applications/$TARGET_NAME"
APP_DISPLAY_NAME="${TARGET_NAME%.app}"

# -----------------------------------------------------------------------------
# Signing identity resolution
# -----------------------------------------------------------------------------

LOCAL_XCCONFIG="$ROOT/MeetAndNote/Local.xcconfig"
CONFIGURED_TEAM=""
if [[ -f "$LOCAL_XCCONFIG" ]]; then
  # Pull `DEVELOPMENT_TEAM = XXXX` from the xcconfig (ignore blank/commented).
  CONFIGURED_TEAM="$(awk -F= '
    /^[[:space:]]*\/\// {next}
    /^[[:space:]]*DEVELOPMENT_TEAM[[:space:]]*=/ {
      gsub(/[[:space:]]/,"",$2); print $2; exit
    }' "$LOCAL_XCCONFIG")"
fi

SIGNING_IDENTITY_SHA=""
SIGNING_IDENTITY_NAME=""
if [[ -n "$CONFIGURED_TEAM" ]]; then
  SIGNING_LINE="$(security find-identity -v -p codesigning 2>/dev/null | grep "($CONFIGURED_TEAM)" | head -1 || true)"
  if [[ -n "$SIGNING_LINE" ]]; then
    SIGNING_IDENTITY_SHA="$(echo "$SIGNING_LINE" | awk '{print $2}')"
    SIGNING_IDENTITY_NAME="$(echo "$SIGNING_LINE" | sed -E 's/^[[:space:]]*[0-9]+\)[[:space:]]*[A-F0-9]+[[:space:]]*"//' | sed 's/"$//')"
    echo "==> Signing identity: $SIGNING_IDENTITY_NAME"
    echo "    (TCC permissions will persist across rebuilds)"
  else
    echo "==> WARNING: Local.xcconfig has DEVELOPMENT_TEAM=$CONFIGURED_TEAM but no matching"
    echo "    Apple Development cert in your login Keychain. Falling back to ad-hoc."
    echo "    Fix: open Xcode → Settings → Accounts → your Apple ID → Personal Team →"
    echo "    Manage Certificates → + → Apple Development, then re-run this script."
  fi
else
  echo "==> No DEVELOPMENT_TEAM configured (ad-hoc signing)."
fi

# -----------------------------------------------------------------------------
# Clean up a legacy un-versioned /Applications/MeetAndNote.app (same bundle id,
# different cdhash → TCC conflict → -3801).
# -----------------------------------------------------------------------------

LEGACY_APP="/Applications/MeetAndNote.app"
if [[ -d "$LEGACY_APP" && "$DEST_APP" != "$LEGACY_APP" ]]; then
  echo "==> Found legacy install at $LEGACY_APP (same bundle id — causes TCC conflicts)"
  osascript -e 'tell application "MeetAndNote" to quit' 2>/dev/null || true
  sleep 1
  TRASH_NAME="MeetAndNote-legacy-$(date +%Y%m%d-%H%M%S).app"
  mv "$LEGACY_APP" "$HOME/.Trash/$TRASH_NAME" 2>/dev/null || rm -rf "$LEGACY_APP"
  echo "    Moved to ~/.Trash/$TRASH_NAME"
  echo
fi

# -----------------------------------------------------------------------------
# Build
# -----------------------------------------------------------------------------

echo "==> Building Release ($CONFIG) …"
if [[ -n "$SIGNING_IDENTITY_SHA" ]]; then
  # Build with ad-hoc signing to avoid the SPM-package signing dance:
  # with real-identity signing Xcode insists every SPM dependency also
  # has "Mac Development" + matching provisioning profile — which free
  # Personal Teams can't produce (SPM dylibs can't be registered with
  # Apple for a free team). We don't care: the .app bundle gets fully
  # re-signed with the real identity AFTER build. TCC keys on the final
  # bundle's TeamIdentifier, not the intermediate SPM-dylib ones.
  BUILD_LOG="$(mktemp -t meetandnote-build.XXXXXX.log)"
  if ! xcodebuild \
       -project "$PROJECT" \
       -scheme "$SCHEME" \
       -configuration "$CONFIG" \
       -destination 'platform=macOS,arch=arm64' \
       -derivedDataPath "$BUILD_DIR" \
       CODE_SIGN_STYLE=Manual \
       DEVELOPMENT_TEAM="" \
       CODE_SIGN_IDENTITY="-" \
       CODE_SIGNING_REQUIRED=NO \
       CODE_SIGNING_ALLOWED=YES \
       build > "$BUILD_LOG" 2>&1; then
    echo "==> BUILD FAILED. Last 60 lines of the build log:"
    tail -60 "$BUILD_LOG"
    echo
    echo "    Full log: $BUILD_LOG"
    exit 1
  fi
  grep -E '(error:|warning:.*\.swift:[0-9]+:[0-9]+)' "$BUILD_LOG" || true
else
  BUILD_LOG="$(mktemp -t meetandnote-build.XXXXXX.log)"
  if ! xcodebuild \
       -project "$PROJECT" \
       -scheme "$SCHEME" \
       -configuration "$CONFIG" \
       -destination 'platform=macOS,arch=arm64' \
       -derivedDataPath "$BUILD_DIR" \
       CODE_SIGN_IDENTITY="-" \
       CODE_SIGNING_REQUIRED=NO \
       CODE_SIGNING_ALLOWED=YES \
       build > "$BUILD_LOG" 2>&1; then
    echo "==> BUILD FAILED. Last 60 lines of the build log:"
    tail -60 "$BUILD_LOG"
    echo
    echo "    Full log: $BUILD_LOG"
    exit 1
  fi
  grep -E '(error:|warning:.*\.swift:[0-9]+:[0-9]+)' "$BUILD_LOG" || true
fi

if [[ ! -d "$SRC_APP" ]]; then
  echo "ERROR: build output not found at $SRC_APP" >&2
  exit 1
fi

# -----------------------------------------------------------------------------
# Quit, copy, re-sign
# -----------------------------------------------------------------------------

echo
echo "==> Quitting any running copy of \"$APP_DISPLAY_NAME\" …"
osascript -e "tell application \"$APP_DISPLAY_NAME\" to quit" 2>/dev/null || true
osascript -e 'tell application "MeetAndNote" to quit' 2>/dev/null || true
sleep 1

echo "==> Installing to \"$DEST_APP\" …"
rm -rf "$DEST_APP"
cp -R "$SRC_APP" "$DEST_APP"

BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$DEST_APP/Contents/Info.plist" 2>/dev/null || echo 'com.sheazuzu.MeetAndNote')"

if [[ -n "$SIGNING_IDENTITY_SHA" ]]; then
  echo "==> Re-signing with $SIGNING_IDENTITY_NAME …"
  # Sign nested bundles first (frameworks + dylibs) with the same identity.
  find "$DEST_APP/Contents/Frameworks" -mindepth 1 -maxdepth 2 \
       \( -name '*.framework' -o -name '*.bundle' -o -name '*.dylib' \) 2>/dev/null \
    | while read -r nested; do
        codesign --force --sign "$SIGNING_IDENTITY_SHA" --timestamp=none "$nested" >/dev/null 2>&1 || true
      done
  # Then the main .app. --preserve-metadata keeps the entitlements embedded
  # by the build; without it signing strips capabilities and permissions
  # like Screen Recording stop working.
  if ! codesign --force --sign "$SIGNING_IDENTITY_SHA" \
       --identifier "$BUNDLE_ID" \
       --preserve-metadata=entitlements,requirements \
       --timestamp=none \
       "$DEST_APP" 2>&1; then
    echo "    WARNING: real-identity signing failed, retrying with ad-hoc."
    SIGNING_IDENTITY_SHA=""
  fi
fi

if [[ -z "$SIGNING_IDENTITY_SHA" ]]; then
  echo "==> Re-signing (ad-hoc, stable identifier) …"
  find "$DEST_APP/Contents/Frameworks" -mindepth 1 -maxdepth 2 \
       \( -name '*.framework' -o -name '*.bundle' -o -name '*.dylib' \) 2>/dev/null \
    | while read -r nested; do
        codesign --force --sign - --timestamp=none "$nested" >/dev/null 2>&1 || true
      done
  codesign --force --sign - \
    --identifier "$BUNDLE_ID" \
    --preserve-metadata=entitlements,requirements \
    --timestamp=none \
    "$DEST_APP" >/dev/null 2>&1 || true
fi

# -----------------------------------------------------------------------------
# Post-install diagnostics + TCC handling
# -----------------------------------------------------------------------------

SIGN_FLAGS="$(codesign -dvvv "$DEST_APP" 2>&1 | grep -E '^flags=' || echo '')"
INSTALLED_TEAM="$(codesign -dvvv "$DEST_APP" 2>&1 | awk -F'=' '/^TeamIdentifier=/ {print $2}')"
IS_ADHOC=0
if [[ "$SIGN_FLAGS" == *"adhoc"* || -z "$INSTALLED_TEAM" || "$INSTALLED_TEAM" == "not set" ]]; then
  IS_ADHOC=1
fi

# Only auto-reset TCC when the installed bundle is actually ad-hoc. With a
# real Team ID the previous grant stays valid across rebuilds — resetting
# would just annoy the user by re-prompting.
if (( IS_ADHOC == 1 )); then
  echo
  echo "==> Ad-hoc build — auto-resetting TCC entries to avoid stale cdhash matches …"
  tccutil reset ScreenCapture "$BUNDLE_ID" 2>&1 | sed 's/^/    /' || true
  tccutil reset Microphone    "$BUNDLE_ID" 2>&1 | sed 's/^/    /' || true
fi

echo
echo "==> Launching …"
open "$DEST_APP"

echo
echo "Done."
echo "  App:        $DEST_APP"
echo "  Bundle ID:  $BUNDLE_ID"
echo "  Team ID:    ${INSTALLED_TEAM:-not set (ad-hoc)}"
echo "  Launch via: Spotlight / Launchpad → \"$APP_DISPLAY_NAME\""
echo "  Rebuild:    ./scripts/install-local.sh"

if (( IS_ADHOC == 1 )); then
  cat <<'EOT'

────────────────────────────────────────────────────────────────────────
⚠️  First-launch flow (MANDATORY for ad-hoc builds, else SCK -3801)
────────────────────────────────────────────────────────────────────────
Round 1 — grant permissions:
  1. Press Start inside the app.
  2. Allow the Microphone prompt.
  3. Open System Settings → Privacy & Security → Screen & System Audio
     Recording and enable "MeetAndNote 2.0".
  4. Fully quit the app with ⌘Q (Dock icon MUST disappear).
Round 2 — real run:
  5. Launch again. Press Start. Works now.

Why two rounds?  macOS writes new TCC entries lazily. The very first
ScreenCaptureKit call after a grant almost always returns -3801; the
process must restart for the new TCC record to take effect.

────────────────────────────────────────────────────────────────────────
💡  Want to stop re-granting on every rebuild?
────────────────────────────────────────────────────────────────────────
Open Xcode → Settings → Accounts, sign in with your free Apple ID, then
paste your 10-char Team ID into MeetAndNote/Local.xcconfig:
    DEVELOPMENT_TEAM = ABCD123XYZ
Re-run this script. TCC will then key on (team, bundle id) instead of
cdhash and the grant lasts forever.
EOT
else
  echo
  echo "✅ Signed with Team ID $INSTALLED_TEAM — TCC permissions persist across rebuilds."
  echo "   First-ever install still needs ONE grant (Microphone + Screen Recording),"
  echo "   then every subsequent rebuild is permission-free."
fi
