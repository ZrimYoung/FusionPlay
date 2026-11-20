#!/bin/bash
source "$(dirname "$0")/env.sh"
xcrun swiftc -D FUSIONPLAY_UI_CHECKS -swift-version 5 -parse-as-library -target arm64-apple-macosx14.0 \
  -module-cache-path "$PROJECT/cache/swift" -framework SwiftUI -framework AppKit \
  "$REPO/macos/Sources/AppLanguage.swift" "$REPO/macos/Sources/CoverLyricsResizeHandle.swift" \
  "$REPO/macos/Tests/CoverLyricsIndicatorSmoke.swift" -o "$PROJECT/build/cover-lyrics-indicator-smoke"
"$PROJECT/build/cover-lyrics-indicator-smoke"
