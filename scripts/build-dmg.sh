#!/bin/bash
set -e

APP_DIR="/Users/sunyang/Library/Developer/Xcode/DerivedData/Orbit-fkcszsgwpkpzkhdvqnneqyzogtzh/Build/Products/Release"
APP_NAME="Orbit"
DMG_NAME="Orbit"
TMP_DIR=$(mktemp -d /tmp/orbit-dmg.XXXXXX)

echo "=== Building DMG for Orbit ==="

# Clean up old DMG
rm -f "$APP_DIR/$DMG_NAME.dmg"

# Prepare DMG contents
echo "→ Copying app to temp dir..."
cp -R "$APP_DIR/$APP_NAME.app" "$TMP_DIR/"

# Create Applications symlink
echo "→ Creating Applications symlink..."
ln -s /Applications "$TMP_DIR/Applications"

# Create DMG
echo "→ Creating DMG..."
hdiutil create -volname "$APP_NAME" \
    -srcfolder "$TMP_DIR" \
    -ov \
    -format UDZO \
    -imagekey zlib-level=9 \
    "$APP_DIR/$DMG_NAME.dmg"

# Cleanup
rm -rf "$TMP_DIR"

echo "=== Done: $APP_DIR/$DMG_NAME.dmg ==="
ls -lh "$APP_DIR/$DMG_NAME.dmg"
