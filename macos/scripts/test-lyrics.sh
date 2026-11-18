#!/bin/bash
source "$(dirname "$0")/env.sh"
xcrun swiftc -swift-version 5 -parse-as-library -module-cache-path "$PROJECT/cache/swift" \
  "$REPO/macos/Sources/LyricsDocument.swift" "$REPO/macos/Tests/LyricsSmoke.swift" \
  -o "$PROJECT/build/lyrics-smoke"
"$PROJECT/build/lyrics-smoke"
