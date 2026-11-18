#!/bin/bash
source "$(dirname "$0")/env.sh"
mkdir -p "$PROJECT/build" "$PROJECT/cache/swift" "$PROJECT/artifacts/native-lyrics-motion-check"
xcrun swiftc -D FUSIONPLAY_UI_CHECKS -swift-version 5 -parse-as-library -target arm64-apple-macosx14.0 \
  -module-cache-path "$PROJECT/cache/swift" -framework SwiftUI -framework AppKit \
  "$REPO/macos/Sources/LyricsStaggerMotion.swift" "$REPO/macos/Sources/LyricsWordLayout.swift" "$REPO/macos/Sources/NativeLyricsReflowText.swift" \
  "$REPO/macos/Sources/LyricsReflowText.swift" "$REPO/macos/Tests/NativeLyricsMotionSmoke.swift" \
  -o "$PROJECT/build/native-lyrics-motion-smoke"
"$PROJECT/build/native-lyrics-motion-smoke" "$PROJECT/artifacts/native-lyrics-motion-check"
