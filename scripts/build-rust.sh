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

echo "  -> Creating universal binaries..."

# Helper: lipo two .a files into universal
make_universal() {
  local name=$1
  local arm64_path=$2
  local x86_path=$3
  if [ -f "$arm64_path" ] && [ -f "$x86_path" ]; then
    lipo -create "$arm64_path" "$x86_path" -output "$UNIVERSAL_DIR/$name"
    echo "     $name"
  else
    echo "     WARNING: $name not found, skipping"
  fi
}

# Main library
make_universal "liborbit_core.a" \
  "$RS_DIR/target/aarch64-apple-darwin/release/liborbit_core.a" \
  "$RS_DIR/target/x86_64-apple-darwin/release/liborbit_core.a"

# sqlite3 (bundled via rusqlite)
ARM_SQLITE=$(find "$RS_DIR/target/aarch64-apple-darwin/release/build" -path "*/libsqlite3-sys*/out/libsqlite3.a" | head -1)
X86_SQLITE=$(find "$RS_DIR/target/x86_64-apple-darwin/release/build" -path "*/libsqlite3-sys*/out/libsqlite3.a" | head -1)
make_universal "libsqlite3.a" "$ARM_SQLITE" "$X86_SQLITE"

# libssh2 (vendored via ssh2 crate)
ARM_SSH2=$(find "$RS_DIR/target/aarch64-apple-darwin/release/build" -path "*/libssh2-sys*/out/build/libssh2.a" | head -1)
X86_SSH2=$(find "$RS_DIR/target/x86_64-apple-darwin/release/build" -path "*/libssh2-sys*/out/build/libssh2.a" | head -1)
make_universal "libssh2.a" "$ARM_SSH2" "$X86_SSH2"

# openssl (vendored via openssl-sys)
ARM_SSL=$(find "$RS_DIR/target/aarch64-apple-darwin/release/build" -path "*/openssl-sys*/out/openssl-build/install/lib/libssl.a" | head -1)
X86_SSL=$(find "$RS_DIR/target/x86_64-apple-darwin/release/build" -path "*/openssl-sys*/out/openssl-build/install/lib/libssl.a" | head -1)
make_universal "libssl.a" "$ARM_SSL" "$X86_SSL"

ARM_CRYPTO=$(find "$RS_DIR/target/aarch64-apple-darwin/release/build" -path "*/openssl-sys*/out/openssl-build/install/lib/libcrypto.a" | head -1)
X86_CRYPTO=$(find "$RS_DIR/target/x86_64-apple-darwin/release/build" -path "*/openssl-sys*/out/openssl-build/install/lib/libcrypto.a" | head -1)
make_universal "libcrypto.a" "$ARM_CRYPTO" "$X86_CRYPTO"

echo "==> Done!"
echo "    Universal libraries:"
ls -la "$UNIVERSAL_DIR"/*.a
echo "    Header: $RS_DIR/include/orbit.h"
