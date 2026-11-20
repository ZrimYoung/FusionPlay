#!/bin/bash
source "$(dirname "$0")/env.sh"
xcrun swiftc -swift-version 5 -parse-as-library -target arm64-apple-macosx14.0 \
  -module-cache-path "$PROJECT/cache/swift" -framework SwiftUI -framework AppKit \
  "$REPO/macos/Sources/AppLanguage.swift" "$REPO/macos/Sources/NarrowPlayerLayout.swift" \
  "$REPO/macos/Sources/PlayerWindowBehavior.swift" "$REPO/macos/Sources/CoverLyricsResizeHandle.swift" \
  "$REPO/macos/Tests/CoverLyricsResizeSmoke.swift" -o "$PROJECT/build/cover-lyrics-resize-smoke"
"$PROJECT/build/cover-lyrics-resize-smoke"
