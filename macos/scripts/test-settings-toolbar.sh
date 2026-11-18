#!/bin/bash
source "$(dirname "$0")/env.sh"
cd "$REPO"
CHECK="$PROJECT/tmp/settings-toolbar-check.app"
mkdir -p "$CHECK/Contents/MacOS" "$CHECK/Contents/Resources" "$PROJECT/tmp/settings-toolbar-check-state"
cp "$REPO/macos/Info.plist" "$CHECK/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier tech.zrim.fusionplay.toolbar-check' "$CHECK/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleExecutable SettingsToolbarCheck' "$CHECK/Contents/Info.plist"
cp -R "$REPO/macos/Resources/"*.lproj "$CHECK/Contents/Resources/"
GENERATED="$PROJECT/build/bindings"
xcrun swiftc -D FUSIONPLAY_UI_CHECKS -swift-version 5 -parse-as-library -target arm64-apple-macosx14.0 \
  -module-cache-path "$PROJECT/cache/swift" -I "$GENERATED" -Xcc "-fmodule-map-file=$GENERATED/FusionPlayBridgeFFI.modulemap" \
  -L "$PROJECT/artifacts/FusionPlay Mac.app/Contents/Frameworks" -lfusionplay_host \
  -Xlinker -rpath -Xlinker "$PROJECT/artifacts/FusionPlay Mac.app/Contents/Frameworks" \
  -framework SwiftUI -framework AppKit -framework MediaPlayer -framework ScreenCaptureKit \
  "$GENERATED/FusionPlayBridge.swift" "$REPO"/macos/Sources/*.swift "$REPO/macos/Tests/SettingsToolbarSmoke.swift" \
  -o "$CHECK/Contents/MacOS/SettingsToolbarCheck"
CFFIXED_USER_HOME="$PROJECT/tmp/settings-toolbar-check-state" \
  FUSIONPLAY_TOOLBAR_CHECK_ROOT="$PROJECT/tmp/settings-toolbar-check-state" \
  FUSIONPLAY_TOOLBAR_CHECK_OUTPUT="$PROJECT/artifacts/settings-toolbar-check.json" \
  FUSIONPLAY_TOOLBAR_CHECK_IMAGE_ROOT="$PROJECT/artifacts" \
  "$CHECK/Contents/MacOS/SettingsToolbarCheck"
