#!/usr/bin/env bash
# Re-generates kmp/ios_bridge/UnfydqryBridge.h from UnfydqryBridge.swift.
#
# Run this after changing the public @objc API in UnfydqryBridge.swift.
# The generated header is committed so Kotlin/Native cinterop works without
# an Xcode build dependency.
#
# Requirements: Xcode Command Line Tools (swiftc in PATH).

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
BRIDGE_DIR="$REPO_ROOT/kmp/ios_bridge"
XCFW="$REPO_ROOT/ios/UnifiedQuery.xcframework"

if [ ! -d "$XCFW" ]; then
  echo "ERROR: $XCFW not found — build it first with scripts/build-xcframework.sh" >&2
  exit 1
fi

# macOS SDK path
SDK="$(xcrun --sdk macosx --show-sdk-path)"

# Swift framework search path inside the XCFramework (macOS slice).
FW_SEARCH="$XCFW/macos-arm64/UnifiedQuery.framework"

swiftc \
  "$BRIDGE_DIR/UnfydqryBridge.swift" \
  -sdk "$SDK" \
  -F "$XCFW/.." \
  -framework UnifiedQuery \
  -module-name UnfydqryBridge \
  -emit-objc-header-path "$BRIDGE_DIR/UnfydqryBridge.h" \
  -parse-as-library

# Prepend the "do not edit" banner.
BANNER='// AUTO-GENERATED — do not edit by hand.\n// Re-generate with: ./kmp/scripts/generate_bridge_header.sh\n'
{ printf "%s" "$BANNER"; cat "$BRIDGE_DIR/UnfydqryBridge.h"; } > /tmp/bridge_header_tmp.h
mv /tmp/bridge_header_tmp.h "$BRIDGE_DIR/UnfydqryBridge.h"

echo "Generated $BRIDGE_DIR/UnfydqryBridge.h"
