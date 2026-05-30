#!/usr/bin/env bash
# Build ios/UnifiedQuery.xcframework from the Rust core and package it as a
# zip suitable for SwiftPM's binaryTarget(url:checksum:).
#
# Outputs (under ios/):
#   UnifiedQuery.xcframework            consumed by Package.swift's local-path fallback
#   UnifiedQuery.xcframework.zip        uploaded to the GitHub Release asset
#   UnifiedQuery.xcframework.zip.sha256 SwiftPM checksum, also printed to stdout
#
# The checksum file is what the release workflow reads back to patch Package.swift.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CORE_DIR="$REPO_ROOT/core"
IOS_DIR="$REPO_ROOT/ios"
BUILD_DIR="$IOS_DIR/build"
GENERATED_DIR="$CORE_DIR/generated/swift"
XCF_DIR="$IOS_DIR/UnifiedQuery.xcframework"
ZIP_PATH="$IOS_DIR/UnifiedQuery.xcframework.zip"

TARGETS=(
  aarch64-apple-darwin
  aarch64-apple-ios
  aarch64-apple-ios-sim
  x86_64-apple-ios
)

echo "==> Ensuring Rust targets"
for t in "${TARGETS[@]}"; do
  rustup target add "$t" >/dev/null
done

echo "==> Building libunfydqry.a for each Apple target"
cd "$CORE_DIR"
for t in "${TARGETS[@]}"; do
  cargo build --release --target "$t"
done

echo "==> Regenerating Swift binding via uniffi-bindgen"
cargo run --quiet --bin uniffi-bindgen -- generate \
  --no-format \
  --library "target/aarch64-apple-ios/release/libunfydqry.a" \
  --language swift \
  --out-dir "generated/swift"

# The committed binding must stay in lockstep with the generated one
# (the swift-tests workflow also enforces this).
cp "$GENERATED_DIR/unfydqry.swift" "$IOS_DIR/Sources/UnifiedQuery/UnifiedQuery.swift"

echo "==> Assembling xcframework slices"
rm -rf "$BUILD_DIR/slices" "$XCF_DIR"
mkdir -p "$BUILD_DIR/slices"

prepare_slice() {
  local slice_dir="$1"
  shift
  local libs=("$@")
  local headers_dir="$slice_dir/Headers"

  mkdir -p "$headers_dir"
  cp "$GENERATED_DIR/unfydqryFFI.h" "$headers_dir/unfydqryFFI.h"
  # xcodebuild expects the modulemap to be named module.modulemap inside the
  # headers directory; uniffi emits it as <namespace>FFI.modulemap.
  cp "$GENERATED_DIR/unfydqryFFI.modulemap" "$headers_dir/module.modulemap"

  if [ ${#libs[@]} -eq 1 ]; then
    cp "${libs[0]}" "$slice_dir/libunfydqry.a"
  else
    lipo -create -output "$slice_dir/libunfydqry.a" "${libs[@]}"
  fi
}

prepare_slice "$BUILD_DIR/slices/ios-arm64" \
  "$CORE_DIR/target/aarch64-apple-ios/release/libunfydqry.a"

prepare_slice "$BUILD_DIR/slices/ios-sim" \
  "$CORE_DIR/target/aarch64-apple-ios-sim/release/libunfydqry.a" \
  "$CORE_DIR/target/x86_64-apple-ios/release/libunfydqry.a"

prepare_slice "$BUILD_DIR/slices/macos-arm64" \
  "$CORE_DIR/target/aarch64-apple-darwin/release/libunfydqry.a"

echo "==> Running xcodebuild -create-xcframework"
xcodebuild -create-xcframework \
  -library "$BUILD_DIR/slices/ios-arm64/libunfydqry.a"   -headers "$BUILD_DIR/slices/ios-arm64/Headers" \
  -library "$BUILD_DIR/slices/ios-sim/libunfydqry.a"     -headers "$BUILD_DIR/slices/ios-sim/Headers" \
  -library "$BUILD_DIR/slices/macos-arm64/libunfydqry.a" -headers "$BUILD_DIR/slices/macos-arm64/Headers" \
  -output "$XCF_DIR" \
  >/dev/null

echo "==> Zipping $XCF_DIR"
rm -f "$ZIP_PATH"
# ditto produces the layout xcodebuild and SwiftPM both expect (preserves the
# top-level UnifiedQuery.xcframework directory inside the zip).
(cd "$IOS_DIR" && ditto -c -k --keepParent "UnifiedQuery.xcframework" "UnifiedQuery.xcframework.zip")

echo "==> Computing SwiftPM checksum"
CHECKSUM=$(cd "$REPO_ROOT" && swift package compute-checksum "$ZIP_PATH")
printf '%s\n' "$CHECKSUM" > "$ZIP_PATH.sha256"
echo "Checksum: $CHECKSUM"
