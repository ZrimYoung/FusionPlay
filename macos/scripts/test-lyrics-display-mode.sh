#!/bin/bash
source "$(dirname "$0")/env.sh"
xcrun swiftc -swift-version 5 -parse-as-library -module-cache-path "$PROJECT/cache/swift" \
  "$REPO/macos/Sources/LyricsDocument.swift" "$REPO/macos/Sources/LyricsDisplayMode.swift" \
  "$REPO/macos/Tests/LyricsDisplayModeSmoke.swift" -o "$PROJECT/build/lyrics-display-mode-smoke"
"$PROJECT/build/lyrics-display-mode-smoke"
