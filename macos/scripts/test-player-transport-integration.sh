#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/env.sh"
CHECK_ROOT="$(mktemp -d "$PROJECT/tmp/player-transport-integration.XXXXXX")"
trap 'rm -rf "$CHECK_ROOT"' EXIT
# Keep formal builds and other checks free to regenerate their own inputs.
cp -R "$PROJECT/build/bindings" "$CHECK_ROOT/bindings"
cp -R "$REPO/macos/Sources" "$CHECK_ROOT/Sources"
cp "$REPO/macos/Tests/PlayerTransportIntegrationSmoke.swift" "$CHECK_ROOT/PlayerTransportIntegrationSmoke.swift"
GENERATED="$CHECK_ROOT/bindings"
xcrun swiftc -D FUSIONPLAY_UI_CHECKS -swift-version 5 -parse-as-library -target "$(uname -m)-apple-macosx14.0" \
  -module-cache-path "$PROJECT/cache/swift" -I "$GENERATED" -Xcc "-fmodule-map-file=$GENERATED/FusionPlayBridgeFFI.modulemap" \
  -L "$PROJECT/artifacts/FusionPlay Mac.app/Contents/Frameworks" -lfusionplay_host \
  -Xlinker -rpath -Xlinker "$PROJECT/artifacts/FusionPlay Mac.app/Contents/Frameworks" \
  -framework SwiftUI -framework AppKit -framework MediaPlayer \
  "$GENERATED/FusionPlayBridge.swift" "$CHECK_ROOT"/Sources/*.swift "$CHECK_ROOT/PlayerTransportIntegrationSmoke.swift" \
  -o "$CHECK_ROOT/PlayerTransportIntegrationCheck"
mkdir -p "$CHECK_ROOT/home/Library/Preferences"
CFFIXED_USER_HOME="$CHECK_ROOT/home" "$CHECK_ROOT/PlayerTransportIntegrationCheck" "$CHECK_ROOT/state"
