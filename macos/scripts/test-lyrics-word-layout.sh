#!/bin/bash
source "$(dirname "$0")/env.sh"
xcrun swiftc -swift-version 5 -parse-as-library -target arm64-apple-macosx14.0 \
  -module-cache-path "$PROJECT/cache/swift" -framework AppKit \
  "$REPO/macos/Sources/LyricsWordLayout.swift" "$REPO/macos/Tests/LyricsWordLayoutSmoke.swift" \
  -o "$PROJECT/build/lyrics-word-layout-smoke"
"$PROJECT/build/lyrics-word-layout-smoke" "$PROJECT/artifacts/lyrics-word-layout-check"
