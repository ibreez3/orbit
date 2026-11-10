#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
APP_DIR="$ROOT_DIR/orbit-app"
DERIVED_DATA="${DERIVED_DATA:-/tmp/orbit-ui-derived}"
DESTINATION="${DESTINATION:-platform=macOS}"

: "${ORBIT_TEST_HOST:?set ORBIT_TEST_HOST}"
: "${ORBIT_TEST_USER:?set ORBIT_TEST_USER}"
: "${ORBIT_TEST_PASSWORD:?set ORBIT_TEST_PASSWORD}"

cd "$APP_DIR"
xcodebuild build-for-testing \
  -project Orbit.xcodeproj \
  -scheme OrbitUITests \
  -destination "$DESTINATION" \
  -derivedDataPath "$DERIVED_DATA" > /dev/null

XCTESTRUN="$(find "$DERIVED_DATA/Build/Products" -maxdepth 1 -name '*.xctestrun' | head -1)"
if [ -z "$XCTESTRUN" ]; then
  echo "xctestrun not found under $DERIVED_DATA/Build/Products" >&2
  exit 1
fi

cleanup() {
  for key in ORBIT_TEST_HOST ORBIT_TEST_USER ORBIT_TEST_PASSWORD; do
    /usr/libexec/PlistBuddy -c "Delete :OrbitUITests:EnvironmentVariables:$key" "$XCTESTRUN" > /dev/null 2>&1 || true
  done
}
trap cleanup EXIT

for pair in \
  "ORBIT_TEST_HOST:$ORBIT_TEST_HOST" \
  "ORBIT_TEST_USER:$ORBIT_TEST_USER" \
  "ORBIT_TEST_PASSWORD:$ORBIT_TEST_PASSWORD"; do
  key="${pair%%:*}"
  value="${pair#*:}"
  if /usr/libexec/PlistBuddy -c "Set :OrbitUITests:EnvironmentVariables:$key $value" "$XCTESTRUN" > /dev/null 2>&1; then
    continue
  fi
  /usr/libexec/PlistBuddy -c "Add :OrbitUITests:EnvironmentVariables:$key string $value" "$XCTESTRUN" > /dev/null
done

xcodebuild test-without-building -xctestrun "$XCTESTRUN" -destination "$DESTINATION"
