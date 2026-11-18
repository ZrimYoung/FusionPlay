#!/bin/bash
source "$(dirname "$0")/env.sh"
xcrun swiftc -swift-version 5 -parse-as-library -target arm64-apple-macosx14.0 \
  -module-cache-path "$PROJECT/cache/swift" -framework SwiftUI \
  "$REPO/macos/Sources/LyricsStaggerMotion.swift" "$REPO/macos/Tests/LyricsStaggerMotionSmoke.swift" \
  -o "$PROJECT/build/lyrics-stagger-motion-smoke"
"$PROJECT/build/lyrics-stagger-motion-smoke"
