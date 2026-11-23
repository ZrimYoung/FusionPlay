#!/bin/bash
source "$(dirname "$0")/env.sh"
xcrun swiftc -swift-version 5 -parse-as-library -target arm64-apple-macosx14.0 \
  -module-cache-path "$PROJECT/cache/swift" \
  "$REPO/macos/Sources/ExpandedLyricsLayout.swift" "$REPO/macos/Tests/ExpandedLyricsLayoutSmoke.swift" \
  -o "$PROJECT/build/expanded-lyrics-layout-smoke"
"$PROJECT/build/expanded-lyrics-layout-smoke"
