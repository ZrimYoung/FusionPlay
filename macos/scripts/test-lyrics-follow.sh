#!/bin/bash
source "$(dirname "$0")/env.sh"
xcrun swiftc -swift-version 5 -parse-as-library -module-cache-path "$PROJECT/cache/swift" \
  "$REPO/macos/Sources/LyricsFollowPosition.swift" "$REPO/macos/Tests/LyricsFollowPositionSmoke.swift" \
  -o "$PROJECT/build/lyrics-follow-smoke"
"$PROJECT/build/lyrics-follow-smoke"
