#!/bin/bash
source "$(dirname "$0")/env.sh"
# Default checks remain alpha-zero and do not create a menu-bar item or take
# focus. Opt into visible interaction/captures only when explicitly requested.
export FUSIONPLAY_MENU_VISUAL_CHECK="${FUSIONPLAY_MENU_VISUAL_CHECK:-0}"
cd "$REPO"
CHECK="$PROJECT/tmp/menu-native-check.app"
mkdir -p "$CHECK/Contents/MacOS" "$CHECK/Contents/Resources"
cp "$REPO/macos/Info.plist" "$CHECK/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier tech.zrim.fusionplay.menu-native-check' "$CHECK/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleExecutable MenuNativeCheck' "$CHECK/Contents/Info.plist"
cp -R "$REPO/macos/Resources/"*.lproj "$CHECK/Contents/Resources/"
GENERATED="$PROJECT/build/bindings"
xcrun swiftc -D FUSIONPLAY_UI_CHECKS -swift-version 5 -parse-as-library -target arm64-apple-macosx14.0 \
  -module-cache-path "$PROJECT/cache/swift" -I "$GENERATED" -Xcc "-fmodule-map-file=$GENERATED/FusionPlayBridgeFFI.modulemap" \
  -L "$PROJECT/artifacts/FusionPlay Mac.app/Contents/Frameworks" -lfusionplay_host \
  -Xlinker -rpath -Xlinker "$PROJECT/artifacts/FusionPlay Mac.app/Contents/Frameworks" \
  -framework SwiftUI -framework AppKit -framework MediaPlayer -framework ScreenCaptureKit \
  "$GENERATED/FusionPlayBridge.swift" "$REPO"/macos/Sources/*.swift "$REPO/macos/Tests/MenuPanelNativeSmoke.swift" \
  -o "$CHECK/Contents/MacOS/MenuNativeCheck"
"$CHECK/Contents/MacOS/MenuNativeCheck" "$PROJECT/artifacts/menu-native-check"
