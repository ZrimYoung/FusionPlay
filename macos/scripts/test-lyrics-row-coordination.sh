#!/bin/bash
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CHECK_ROOT="$(mktemp -d /tmp/fusionplay-lyrics-row-coordination.XXXXXX)"
CACHE="${FUSIONPLAY_LYRICS_COORDINATION_CACHE:-/tmp/fusionplay-lyrics-coordination-cache}"
mkdir -p "$CACHE"
nice -n 10 xcrun swiftc -D FUSIONPLAY_LYRICS_COORDINATION_CHECKS -D FUSIONPLAY_REFLOW_BENCHMARK -swift-version 5 -parse-as-library -target arm64-apple-macosx14.0 \
  -module-cache-path "$CACHE" -framework SwiftUI -framework AppKit \
  "$REPO/macos/Sources/LyricsTypography.swift" "$REPO/macos/Sources/AppTypography.swift" "$REPO/macos/Sources/AppLanguage.swift" \
  "$REPO/macos/Sources/LyricsDocument.swift" "$REPO/macos/Sources/LyricsFollowPosition.swift" "$REPO/macos/Sources/LyricsViewportAnchor.swift" \
  "$REPO/macos/Sources/LyricsStaggerMotion.swift" "$REPO/macos/Sources/LyricsWordLayout.swift" "$REPO/macos/Sources/NativeLyricsReflowText.swift" \
  "$REPO/macos/Sources/LyricsReflowText.swift" "$REPO/macos/Sources/LyricsView.swift" "$REPO/macos/Tests/LyricsRowCoordinationSmoke.swift" \
  -o "$CHECK_ROOT/lyrics-row-coordination-smoke"
nice -n 10 "$CHECK_ROOT/lyrics-row-coordination-smoke"
