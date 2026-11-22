#!/bin/bash
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PROJECT="${FUSIONPLAY_PROJECT_ROOT:-$(dirname "$REPO")}"
CHECK_ROOT="$(mktemp -d "$PROJECT/tmp/player-responsive-motion.XXXXXX")"
CHECK="$CHECK_ROOT/PlayerResponsiveMotionCheck.app"
OUTPUT="$PROJECT/artifacts/player-responsive-motion-check"
mkdir -p "$CHECK/Contents/MacOS" "$CHECK/Contents/Resources" "$CHECK/Contents/Frameworks" "$CHECK_ROOT/home/Library/Preferences" "$OUTPUT"
rm -f "$OUTPUT/responsive-motion.json"
cp -R "${FUSIONPLAY_RESPONSIVE_CHECK_BINDINGS:-$PROJECT/build/bindings}" "$CHECK_ROOT/bindings"
cp "${FUSIONPLAY_RESPONSIVE_CHECK_LIBRARY:-$PROJECT/artifacts/FusionPlay Mac.app/Contents/Frameworks/libfusionplay_host.dylib}" "$CHECK/Contents/Frameworks/"
cp "$REPO/macos/Info.plist" "$CHECK/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier tech.zrim.fusionplay.responsive-motion-check' "$CHECK/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleExecutable PlayerResponsiveMotionCheck' "$CHECK/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :LSUIElement true' "$CHECK/Contents/Info.plist"
cp -R "$REPO/macos/Resources/"*.lproj "$CHECK/Contents/Resources/"
GENERATED="$CHECK_ROOT/bindings"
xcrun swiftc -D FUSIONPLAY_UI_CHECKS -swift-version 5 -parse-as-library -target arm64-apple-macosx14.0 \
  -module-cache-path "$PROJECT/cache/swift" -I "$GENERATED" -Xcc "-fmodule-map-file=$GENERATED/FusionPlayBridgeFFI.modulemap" \
  -L "$CHECK/Contents/Frameworks" -lfusionplay_host -Xlinker -rpath -Xlinker '@executable_path/../Frameworks' \
  -framework SwiftUI -framework AppKit -framework MediaPlayer -framework ScreenCaptureKit \
  "$GENERATED/FusionPlayBridge.swift" "$REPO"/macos/Sources/*.swift "$REPO/macos/Tests/PlayerResponsiveMotionSmoke.swift" \
  -o "$CHECK/Contents/MacOS/PlayerResponsiveMotionCheck"
codesign --force --sign - "$CHECK/Contents/Frameworks/libfusionplay_host.dylib"
codesign --force --sign - "$CHECK"
codesign --verify --deep --strict "$CHECK"
CFFIXED_USER_HOME="$CHECK_ROOT/home" FUSIONPLAY_RESPONSIVE_CHECK_ROOT="$CHECK_ROOT" \
  FUSIONPLAY_RESPONSIVE_CHECK_OUTPUT="$OUTPUT" "$CHECK/Contents/MacOS/PlayerResponsiveMotionCheck" 2>&1 | tee "$OUTPUT/run.log"
if rg -q 'Multiple inserted views.*isSource.*true' "$OUTPUT/run.log"; then
  echo 'FAIL: multiple matchedGeometry source views were inserted' >&2
  exit 1
fi
