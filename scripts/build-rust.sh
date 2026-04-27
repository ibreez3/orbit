#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
RS_DIR="$ROOT_DIR/orbit-rs"

echo "==> Building orbit-core (Rust static library)..."

ARCH=$(uname -m)
if [ "$ARCH" = "arm64" ]; then
    TARGET="aarch64-apple-darwin"
elif [ "$ARCH" = "x86_64" ]; then
    TARGET="x86_64-apple-darwin"
else
    echo "Unsupported architecture: $ARCH"
    exit 1
fi

cd "$RS_DIR"
cargo build --release --target "$TARGET"

LIB_DIR="$RS_DIR/target/$TARGET/release"
echo "==> Static library: $LIB_DIR/liborbit_core.a"
echo "==> Header: $RS_DIR/include/orbit.h"
echo ""
echo "To build the Xcode project:"
echo "  1. Open orbit-app/Orbit.xcodeproj in Xcode"
echo "  2. Add '$RS_DIR/include' to Header Search Paths"
echo "  3. Add '$LIB_DIR/liborbit_core.a' to 'Other Linker Flags'"
echo "  4. Add 'Security.framework' to Linked Frameworks"
echo "  5. Build and Run"
