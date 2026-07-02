#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
RS_DIR="$ROOT_DIR/orbit-rs"
DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-13.0}"

echo "==> Building orbit-core (Rust static library for Apple Silicon)..."
echo "    MACOSX_DEPLOYMENT_TARGET=$DEPLOYMENT_TARGET"

cd "$RS_DIR"

echo "  -> aarch64-apple-darwin (arm64)..."
MACOSX_DEPLOYMENT_TARGET="$DEPLOYMENT_TARGET" cargo build --release --target aarch64-apple-darwin

OUTPUT_DIR="$RS_DIR/target/apple-silicon-apple-darwin/release"
rm -rf "$OUTPUT_DIR"
mkdir -p "$OUTPUT_DIR"

echo "  -> Copying arm64 static libraries..."

copy_lib() {
  local name=$1
  local path=$2
  if [ -f "$path" ]; then
    cp "$path" "$OUTPUT_DIR/$name"
    echo "     $name"
  else
    echo "     ERROR: $name not found at $path" >&2
    exit 1
  fi
}

copy_lib "liborbit_core.a" \
  "$RS_DIR/target/aarch64-apple-darwin/release/liborbit_core.a"

# sqlite3 (bundled via rusqlite)
ARM_SQLITE=$(find "$RS_DIR/target/aarch64-apple-darwin/release/build" -path "*/libsqlite3-sys*/out/libsqlite3.a" | head -1)
copy_lib "libsqlite3.a" "$ARM_SQLITE"

# libssh2 (vendored via ssh2 crate)
ARM_SSH2=$(find "$RS_DIR/target/aarch64-apple-darwin/release/build" -path "*/libssh2-sys*/out/build/libssh2.a" | head -1)
copy_lib "libssh2.a" "$ARM_SSH2"

# openssl (vendored via openssl-sys)
ARM_SSL=$(find "$RS_DIR/target/aarch64-apple-darwin/release/build" -path "*/openssl-sys*/out/openssl-build/install/lib/libssl.a" | head -1)
copy_lib "libssl.a" "$ARM_SSL"

ARM_CRYPTO=$(find "$RS_DIR/target/aarch64-apple-darwin/release/build" -path "*/openssl-sys*/out/openssl-build/install/lib/libcrypto.a" | head -1)
copy_lib "libcrypto.a" "$ARM_CRYPTO"

echo "==> Done!"
echo "    Apple Silicon libraries:"
ls -la "$OUTPUT_DIR"/*.a
echo "    Header: $RS_DIR/include/orbit.h"
