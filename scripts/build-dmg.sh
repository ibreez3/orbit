#!/bin/bash
set -euo pipefail

usage() {
    echo "Usage: $0 <Orbit.app path> <output.dmg path> [volume name]"
}

APP_PATH="${1:-${APP_PATH:-}}"
OUTPUT_PATH="${2:-${OUTPUT_PATH:-}}"
VOLUME_NAME="${3:-${VOLUME_NAME:-Orbit}}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TMP_DIR=""
MOUNT_DIR=""
MOUNT_ATTACHED=0

cleanup() {
    if [ "$MOUNT_ATTACHED" -eq 1 ] && [ -n "$MOUNT_DIR" ]; then
        hdiutil detach "$MOUNT_DIR" -quiet 2>/dev/null || true
    fi
    if [ -n "$MOUNT_DIR" ]; then
        rmdir "$MOUNT_DIR" 2>/dev/null || true
    fi
    if [ -n "$TMP_DIR" ]; then
        rm -rf "$TMP_DIR"
    fi
}
trap cleanup EXIT

if [ -z "$APP_PATH" ] || [ -z "$OUTPUT_PATH" ]; then
    usage
    exit 1
fi

if [ ! -d "$APP_PATH" ]; then
    echo "ERROR: app bundle not found: $APP_PATH" >&2
    exit 1
fi

echo "==> Verifying app bundle..."
bash "$SCRIPT_DIR/verify-app.sh" "$APP_PATH"

TMP_DIR="$(mktemp -d /tmp/orbit-dmg.XXXXXX)"

mkdir -p "$(dirname "$OUTPUT_PATH")"
rm -f "$OUTPUT_PATH"

echo "==> Preparing DMG contents..."
ditto "$APP_PATH" "$TMP_DIR/Orbit.app"
ln -s /Applications "$TMP_DIR/Applications"

echo "==> Creating DMG..."
hdiutil create \
    -volname "$VOLUME_NAME" \
    -srcfolder "$TMP_DIR" \
    -fs HFS+ \
    -ov \
    -format UDZO \
    -imagekey zlib-level=9 \
    "$OUTPUT_PATH"

if [ "${SIGN_DMG:-1}" = "1" ]; then
    echo "==> Signing DMG locally..."
    codesign --force --sign - "$OUTPUT_PATH"
fi

echo "==> Verifying DMG..."
codesign --verify --verbose=4 "$OUTPUT_PATH"
hdiutil verify "$OUTPUT_PATH"

echo "==> Verifying mounted DMG contents..."
MOUNT_DIR="$(mktemp -d /tmp/orbit-dmg-check.XXXXXX)"
hdiutil attach "$OUTPUT_PATH" -mountpoint "$MOUNT_DIR" -nobrowse -quiet
MOUNT_ATTACHED=1
bash "$SCRIPT_DIR/verify-app.sh" "$MOUNT_DIR/Orbit.app"
hdiutil detach "$MOUNT_DIR" -quiet
MOUNT_ATTACHED=0
rmdir "$MOUNT_DIR"
MOUNT_DIR=""

echo "==> Done: $OUTPUT_PATH"
ls -lh "$OUTPUT_PATH"
