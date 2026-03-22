#!/usr/bin/env bash
set -euo pipefail

# ─── Config ───────────────────────────────────────────────────────────────────
APP_NAME="dispatch-daemon"
SCHEME="dispatch-daemon"
BUNDLE_ID="com.omgandhi.dispatch-daemon"
VOLUME_NAME="Dispatch Daemon"
BUILD_DIR="$(pwd)/build"
ARCHIVE_PATH="$BUILD_DIR/$APP_NAME.xcarchive"
EXPORT_DIR="$BUILD_DIR/export"
DMG_PATH="$BUILD_DIR/$APP_NAME.dmg"

# ─── Required env vars ────────────────────────────────────────────────────────
# Set these or export them before running:
#   APPLE_ID         — your Apple ID email
#   APPLE_APP_PASSWORD — app-specific password from appleid.apple.com
#   TEAM_ID          — your 10-char Apple Developer Team ID
#   SIGN_IDENTITY    — e.g. "Developer ID Application: Your Name (TEAMID)"

: "${APPLE_ID:?Set APPLE_ID}"
: "${APPLE_APP_PASSWORD:?Set APPLE_APP_PASSWORD}"
: "${TEAM_ID:?Set TEAM_ID}"
: "${SIGN_IDENTITY:?Set SIGN_IDENTITY}"

# ─── ExportOptions.plist ──────────────────────────────────────────────────────
EXPORT_OPTIONS="$BUILD_DIR/ExportOptions.plist"
mkdir -p "$BUILD_DIR"
cat > "$EXPORT_OPTIONS" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>developer-id</string>
    <key>signingStyle</key>
    <string>automatic</string>
    <key>teamID</key>
    <string>${TEAM_ID}</string>
</dict>
</plist>
PLIST

# ─── 1. Archive ───────────────────────────────────────────────────────────────
echo "▶ Archiving..."
xcodebuild archive \
  -scheme "$SCHEME" \
  -archivePath "$ARCHIVE_PATH" \
  -destination "platform=macOS,arch=arm64" \
  DEVELOPMENT_TEAM="$TEAM_ID"

# ─── 2. Export ────────────────────────────────────────────────────────────────
echo "▶ Exporting..."
xcodebuild -exportArchive \
  -archivePath "$ARCHIVE_PATH" \
  -exportPath "$EXPORT_DIR" \
  -exportOptionsPlist "$EXPORT_OPTIONS"

APP_PATH="$EXPORT_DIR/$APP_NAME.app"

if [ ! -d "$APP_PATH" ]; then
  echo "❌ Export failed — $APP_PATH not found"
  exit 1
fi

# ─── 3. Create DMG ───────────────────────────────────────────────────────────
echo "▶ Creating DMG..."
rm -f "$DMG_PATH"
hdiutil create \
  -volname "$VOLUME_NAME" \
  -srcfolder "$APP_PATH" \
  -ov \
  -format UDZO \
  "$DMG_PATH"

# ─── 4. Sign DMG ─────────────────────────────────────────────────────────────
echo "▶ Signing DMG..."
codesign \
  --sign "$SIGN_IDENTITY" \
  --timestamp \
  "$DMG_PATH"

# ─── 5. Notarize ─────────────────────────────────────────────────────────────
echo "▶ Notarizing (this may take a few minutes)..."
xcrun notarytool submit "$DMG_PATH" \
  --apple-id "$APPLE_ID" \
  --password "$APPLE_APP_PASSWORD" \
  --team-id "$TEAM_ID" \
  --wait

# ─── 6. Staple ───────────────────────────────────────────────────────────────
echo "▶ Stapling..."
xcrun stapler staple "$DMG_PATH"

echo ""
echo "✅ Done: $DMG_PATH"
