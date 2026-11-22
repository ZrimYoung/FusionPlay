#!/bin/bash
source "$(dirname "$0")/env.sh"
# The application build regenerates these inputs; compile against this check's
# own snapshot so a concurrent release build cannot invalidate swiftc inputs.
CHECK_TMP="$(mktemp -d "$PROJECT/tmp/menu-corners-compile.XXXXXX")"
trap 'rm -rf "$CHECK_TMP"' EXIT
cp -R "$PROJECT/build/bindings" "$CHECK_TMP/bindings"
GENERATED="$CHECK_TMP/bindings"
CHECK="$PROJECT/build/menu-panel-corners-smoke"
xcrun swiftc -D FUSIONPLAY_UI_CHECKS -swift-version 5 -parse-as-library -target arm64-apple-macosx14.0 \
  -module-cache-path "$PROJECT/cache/swift" -I "$GENERATED" -Xcc "-fmodule-map-file=$GENERATED/FusionPlayBridgeFFI.modulemap" \
  -L "$PROJECT/artifacts/FusionPlay Mac.app/Contents/Frameworks" -lfusionplay_host \
  -Xlinker -rpath -Xlinker "$PROJECT/artifacts/FusionPlay Mac.app/Contents/Frameworks" \
  -framework SwiftUI -framework AppKit -framework MediaPlayer \
  "$GENERATED/FusionPlayBridge.swift" "$REPO"/macos/Sources/*.swift "$REPO/macos/Tests/MenuPanelCornersSmoke.swift" -o "$CHECK"
"$CHECK" "$PROJECT/tmp/menu-corners-isolated-state"
