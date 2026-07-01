#!/bin/bash
set -euo pipefail

usage() {
    echo "Usage: $0 <Orbit.app path> <output.dmg path> [volume name]"
}

APP_PATH="${1:-${APP_PATH:-}}"
OUTPUT_PATH="${2:-${OUTPUT_PATH:-}}"
VOLUME_NAME="${3:-${VOLUME_NAME:-Orbit}}"

if [ -z "$APP_PATH" ] || [ -z "$OUTPUT_PATH" ]; then
    usage
    exit 1
fi

if [ ! -d "$APP_PATH" ]; then
    echo "ERROR: app bundle not found: $APP_PATH" >&2
    exit 1
fi

TMP_DIR="$(mktemp -d /tmp/orbit-dmg.XXXXXX)"
trap 'rm -rf "$TMP_DIR"' EXIT

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

echo "==> Done: $OUTPUT_PATH"
ls -lh "$OUTPUT_PATH"
