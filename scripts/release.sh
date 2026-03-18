#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# ClaudeNotch Release Script
#
# Builds, signs, notarizes, creates DMG, and generates Sparkle appcast.
#
# Usage:
#   ./scripts/release.sh
#
# Prerequisites:
#   - Xcode with Developer ID certificate installed
#   - dmgbuild (pip3 install 'dmgbuild[badge_icons]')
#   - Sparkle CLI tools in Configuration/sparkle/bin/
#   - Sparkle EdDSA private key in Keychain
#
# Before running, bump the version in Xcode:
#   - MARKETING_VERSION (e.g., 2.8.0)
#   - CURRENT_PROJECT_VERSION (e.g., 280) — must be strictly increasing
# =============================================================================

# --- Configuration (edit these for your environment) ---
SCHEME="claudeNotch"
PROJECT="claudeNotch.xcodeproj"
APP_NAME="claudeNotch"
GITHUB_REPO="hpriehle/claude-notch"

# Code signing — replace with your Developer ID values
DEVELOPER_ID_IDENTITY="Developer ID Application"  # or full identity string
DEVELOPMENT_TEAM=""  # Your Apple Team ID (e.g., "A1B2C3D4E5")

# Notarization — replace with your Apple credentials
APPLE_ID=""           # Your Apple ID email
APPLE_TEAM_ID=""      # Same as DEVELOPMENT_TEAM
# Store the app-specific password in Keychain:
#   xcrun notarytool store-credentials "notarytool-profile" \
#     --apple-id "$APPLE_ID" --team-id "$APPLE_TEAM_ID" --password "your-app-specific-password"
NOTARYTOOL_PROFILE="notarytool-profile"

# --- Derived paths ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
BUILD_DIR="$ROOT_DIR/build"
ARCHIVE_PATH="$BUILD_DIR/ClaudeNotch.xcarchive"
EXPORT_PATH="$BUILD_DIR/Release"
DMG_OUTPUT="$BUILD_DIR/ClaudeNotch.dmg"
SPARKLE_BIN="$ROOT_DIR/Configuration/sparkle/bin"
APPCAST_DIR="$ROOT_DIR/docs"

die() {
  echo "Error: $*" >&2
  exit 1
}

# --- Validation ---
[ -f "$ROOT_DIR/$PROJECT/project.pbxproj" ] || die "Project not found. Run from repo root or check PROJECT variable."
[ -x "$SPARKLE_BIN/sign_update" ] || die "Sparkle CLI tools not found at $SPARKLE_BIN"
[ -n "$DEVELOPMENT_TEAM" ] || die "DEVELOPMENT_TEAM is not set. Edit this script with your Apple Team ID."
[ -n "$APPLE_ID" ] || die "APPLE_ID is not set. Edit this script with your Apple ID email."

# --- Step 1: Clean & Archive ---
echo "==> Archiving $SCHEME (Release)..."
rm -rf "$BUILD_DIR"
mkdir -p "$EXPORT_PATH"

xcodebuild archive \
  -project "$ROOT_DIR/$PROJECT" \
  -scheme "$SCHEME" \
  -configuration Release \
  -archivePath "$ARCHIVE_PATH" \
  CODE_SIGN_IDENTITY="$DEVELOPER_ID_IDENTITY" \
  DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM" \
  CODE_SIGN_STYLE="Manual" \
  OTHER_CODE_SIGN_FLAGS="--timestamp" \
  -quiet

echo "==> Archive complete."

# --- Step 2: Export .app from archive ---
echo "==> Exporting app from archive..."
cp -R "$ARCHIVE_PATH/Products/Applications/$APP_NAME.app" "$EXPORT_PATH/"

# Read version info from the built app
APP_BUNDLE="$EXPORT_PATH/$APP_NAME.app"
MARKETING_VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP_BUNDLE/Contents/Info.plist")
BUILD_NUMBER=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$APP_BUNDLE/Contents/Info.plist")
echo "    Version: $MARKETING_VERSION (build $BUILD_NUMBER)"

# --- Step 3: Notarize ---
echo "==> Creating ZIP for notarization..."
NOTARIZE_ZIP="$BUILD_DIR/ClaudeNotch-notarize.zip"
ditto -c -k --keepParent "$APP_BUNDLE" "$NOTARIZE_ZIP"

echo "==> Submitting for notarization..."
xcrun notarytool submit "$NOTARIZE_ZIP" \
  --keychain-profile "$NOTARYTOOL_PROFILE" \
  --wait

echo "==> Stapling notarization ticket..."
xcrun stapler staple "$APP_BUNDLE"

# --- Step 4: Create DMG ---
echo "==> Creating DMG..."
"$ROOT_DIR/Configuration/dmg/create_dmg.sh" \
  "$APP_BUNDLE" \
  "$DMG_OUTPUT" \
  "ClaudeNotch"

echo "    DMG: $DMG_OUTPUT"

# --- Step 5: Sign DMG with Sparkle EdDSA key ---
echo "==> Signing DMG with Sparkle EdDSA key..."
SPARKLE_SIG=$("$SPARKLE_BIN/sign_update" "$DMG_OUTPUT")
echo "    Signature info: $SPARKLE_SIG"

# --- Step 6: Generate/update appcast.xml ---
echo "==> Generating appcast..."
mkdir -p "$APPCAST_DIR"

# generate_appcast needs the DMG in a directory to scan
APPCAST_STAGING="$BUILD_DIR/appcast_staging"
mkdir -p "$APPCAST_STAGING"
cp "$DMG_OUTPUT" "$APPCAST_STAGING/"

# If an existing appcast exists, copy it so generate_appcast can append to it
if [ -f "$APPCAST_DIR/appcast.xml" ]; then
  cp "$APPCAST_DIR/appcast.xml" "$APPCAST_STAGING/"
fi

"$SPARKLE_BIN/generate_appcast" "$APPCAST_STAGING" \
  --download-url-prefix "https://github.com/$GITHUB_REPO/releases/download/v$MARKETING_VERSION/"

cp "$APPCAST_STAGING/appcast.xml" "$APPCAST_DIR/appcast.xml"

echo ""
echo "============================================"
echo "  Release build complete!"
echo "============================================"
echo ""
echo "  Version:  $MARKETING_VERSION (build $BUILD_NUMBER)"
echo "  DMG:      $DMG_OUTPUT"
echo "  Appcast:  $APPCAST_DIR/appcast.xml"
echo ""
echo "  Next steps:"
echo "  1. git add docs/appcast.xml && git commit -m 'Update appcast for v$MARKETING_VERSION' && git push"
echo "  2. gh release create v$MARKETING_VERSION --title 'ClaudeNotch v$MARKETING_VERSION' $DMG_OUTPUT"
echo "  3. Verify at: https://hpriehle.github.io/claude-notch/appcast.xml"
echo ""
