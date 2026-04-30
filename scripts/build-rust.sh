#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
RS_DIR="$ROOT_DIR/orbit-rs"

echo "==> Building orbit-core (Rust universal static library)..."

cd "$RS_DIR"

# Build both architectures
echo "  -> aarch64-apple-darwin (arm64)..."
cargo build --release --target aarch64-apple-darwin

echo "  -> x86_64-apple-darwin (x86_64)..."
cargo build --release --target x86_64-apple-darwin

# Create universal binary with lipo
UNIVERSAL_DIR="$RS_DIR/target/universal-apple-darwin/release"
rm -rf "$UNIVERSAL_DIR"
mkdir -p "$UNIVERSAL_DIR"

echo "  -> Creating universal binary..."
lipo -create \
  "$RS_DIR/target/aarch64-apple-darwin/release/liborbit_core.a" \
  "$RS_DIR/target/x86_64-apple-darwin/release/liborbit_core.a" \
  -output "$UNIVERSAL_DIR/liborbit_core.a"

echo "==> Done!"
echo "    Universal library: $UNIVERSAL_DIR/liborbit_core.a"
echo "    Header: $RS_DIR/include/orbit.h"
