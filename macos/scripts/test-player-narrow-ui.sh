#!/bin/bash
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PROJECT="${FUSIONPLAY_PROJECT_ROOT:-$(dirname "$REPO")}"
CHECK_ROOT="$(mktemp -d "$PROJECT/tmp/player-narrow-ui.XXXXXX")"
CHECK="$CHECK_ROOT/PlayerNarrowUICheck.app"
OUTPUT="$PROJECT/artifacts/player-narrow-ui-check"
mkdir -p "$CHECK/Contents/MacOS" "$CHECK/Contents/Resources" "$CHECK/Contents/Frameworks" "$CHECK_ROOT/home/Library/Preferences" "$OUTPUT"
# Freeze both halves of the FFI before compiling; an unrelated app rebuild must
# not overwrite pages of the dylib already mapped by this isolated test process.
cp -R "${FUSIONPLAY_NARROW_CHECK_BINDINGS:-$PROJECT/build/bindings}" "$CHECK_ROOT/bindings"
cp "${FUSIONPLAY_NARROW_CHECK_LIBRARY:-$PROJECT/artifacts/FusionPlay Mac.app/Contents/Frameworks/libfusionplay_host.dylib}" "$CHECK/Contents/Frameworks/"
cp "$REPO/macos/Info.plist" "$CHECK/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier tech.zrim.fusionplay.narrow-ui-check' "$CHECK/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleExecutable PlayerNarrowUICheck' "$CHECK/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :LSUIElement true' "$CHECK/Contents/Info.plist"
cp -R "$REPO/macos/Resources/"*.lproj "$CHECK/Contents/Resources/"
GENERATED="$CHECK_ROOT/bindings"
TEST_SOURCE="$REPO/macos/Tests/PlayerLayoutSilentSmoke.swift"
if [[ "${FUSIONPLAY_UI_INTERACTIVE:-0}" == 1 ]]; then TEST_SOURCE="$REPO/macos/Tests/PlayerNarrowWindowSmoke.swift"; fi
xcrun swiftc -D FUSIONPLAY_UI_CHECKS -swift-version 5 -parse-as-library -target arm64-apple-macosx14.0 \
  -module-cache-path "$PROJECT/cache/swift" -I "$GENERATED" -Xcc "-fmodule-map-file=$GENERATED/FusionPlayBridgeFFI.modulemap" \
  -L "$CHECK/Contents/Frameworks" -lfusionplay_host -Xlinker -rpath -Xlinker '@executable_path/../Frameworks' \
  -framework SwiftUI -framework AppKit -framework MediaPlayer -framework ScreenCaptureKit \
  "$GENERATED/FusionPlayBridge.swift" "$REPO"/macos/Sources/*.swift "$TEST_SOURCE" \
  -o "$CHECK/Contents/MacOS/PlayerNarrowUICheck"
codesign --force --sign - "$CHECK/Contents/Frameworks/libfusionplay_host.dylib"
codesign --force --sign - "$CHECK"
codesign --verify --deep --strict "$CHECK"
CFFIXED_USER_HOME="$CHECK_ROOT/home" FUSIONPLAY_NARROW_CHECK_ROOT="$CHECK_ROOT" \
  FUSIONPLAY_NARROW_CHECK_OUTPUT="$OUTPUT" "$CHECK/Contents/MacOS/PlayerNarrowUICheck"
