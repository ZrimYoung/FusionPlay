#!/bin/bash
source "$(dirname "$0")/env.sh"
mkdir -p "$PROJECT/build" "$PROJECT/cache/swift" "$PROJECT/artifacts/lyrics-anchor-check"
xcrun swiftc -D FUSIONPLAY_UI_CHECKS -swift-version 5 -parse-as-library -target arm64-apple-macosx14.0 \
  -module-cache-path "$PROJECT/cache/swift" -framework SwiftUI -framework AppKit \
  "$REPO/macos/Sources/LyricsTypography.swift" "$REPO/macos/Sources/AppTypography.swift" "$REPO/macos/Sources/AppLanguage.swift" \
  "$REPO/macos/Sources/LyricsDocument.swift" "$REPO/macos/Sources/LyricsFollowPosition.swift" "$REPO/macos/Sources/LyricsViewportAnchor.swift" \
  "$REPO/macos/Sources/LyricsStaggerMotion.swift" "$REPO/macos/Sources/LyricsWordLayout.swift" "$REPO/macos/Sources/NativeLyricsReflowText.swift" \
  "$REPO/macos/Sources/LyricsReflowText.swift" "$REPO/macos/Sources/LyricsView.swift" \
  "$REPO/macos/Tests/LyricsViewportHeightSmoke.swift" -o "$PROJECT/build/lyrics-viewport-height-smoke"
"$PROJECT/build/lyrics-viewport-height-smoke" "$PROJECT/artifacts/lyrics-anchor-check/viewport-height${FUSIONPLAY_HEIGHT_BASELINE:+-baseline}.json"
