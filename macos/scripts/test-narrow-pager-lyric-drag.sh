#!/bin/bash
source "$(dirname "$0")/env.sh"
mkdir -p "$PROJECT/build" "$PROJECT/cache/swift"
xcrun swiftc -swift-version 5 -parse-as-library -target arm64-apple-macosx14.0 \
  -module-cache-path "$PROJECT/cache/swift" -framework SwiftUI -framework AppKit \
  "$REPO/macos/Sources/AppTypography.swift" "$REPO/macos/Sources/AppLanguage.swift" \
  "$REPO/macos/Sources/LyricsDisplayMode.swift" "$REPO/macos/Sources/NarrowPlayerLayout.swift" \
  "$REPO/macos/Sources/PlayerPresentationPolicy.swift" "$REPO/macos/Sources/PlayerPagingDragExclusion.swift" \
  "$REPO/macos/Sources/PlayerNarrowPager.swift" "$REPO/macos/Tests/NarrowPagerLyricDragSmoke.swift" \
  -o "$PROJECT/build/narrow-pager-lyric-drag-smoke"
"$PROJECT/build/narrow-pager-lyric-drag-smoke"
FUSIONPLAY_LYRIC_DRAG_FLIPPED=1 "$PROJECT/build/narrow-pager-lyric-drag-smoke"
