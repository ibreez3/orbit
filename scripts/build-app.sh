#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
APP_DIR="$ROOT_DIR/orbit-app"

echo "==> Generating Xcode project..."
cd "$APP_DIR"
xcodegen generate

echo "==> Building Orbit (Release, universal)..."
xcodebuild -project Orbit.xcodeproj \
    -scheme Orbit \
    -configuration Release \
    -arch arm64 -arch x86_64 \
    ONLY_ACTIVE_ARCH=NO \
    build

PRODUCT_DIR="$(
    xcodebuild -project Orbit.xcodeproj -scheme Orbit -configuration Release -showBuildSettings \
    | grep -m1 "BUILT_PRODUCTS_DIR" | awk '{print $3}'
)"
APP_PATH="$PRODUCT_DIR/Orbit.app"

echo "==> Done!"
echo "    App: $APP_PATH"
echo "    Run: open \"$APP_PATH\""
