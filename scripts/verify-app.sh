#!/bin/bash
set -euo pipefail

usage() {
    echo "Usage: $0 <Orbit.app path>"
}

APP_PATH="${1:-${APP_PATH:-}}"

if [ -z "$APP_PATH" ]; then
    usage
    exit 1
fi

if [ ! -d "$APP_PATH" ]; then
    echo "ERROR: app bundle not found: $APP_PATH" >&2
    exit 1
fi

ENTITLEMENTS="$(mktemp /tmp/orbit-entitlements.XXXXXX.plist)"
cleanup() {
    rm -f "$ENTITLEMENTS"
}
trap cleanup EXIT

expect_entitlement() {
    local key=$1
    local expected=$2
    local actual

    actual="$(/usr/libexec/PlistBuddy -c "Print :$key" "$ENTITLEMENTS")"
    if [ "$actual" != "$expected" ]; then
        echo "ERROR: entitlement $key expected $expected, got $actual" >&2
        exit 1
    fi
}

test -x "$APP_PATH/Contents/MacOS/Orbit"
codesign --verify --deep --strict --verbose=4 "$APP_PATH"
codesign -d --entitlements :- "$APP_PATH" > "$ENTITLEMENTS" 2>/dev/null

expect_entitlement "com.apple.security.network.client" "true"
expect_entitlement "com.apple.security.network.server" "true"
expect_entitlement "com.apple.security.files.user-selected.read-write" "true"
expect_entitlement "com.apple.security.app-sandbox" "false"

echo "Verified Orbit.app: $APP_PATH"
