#!/bin/bash
source "$(dirname "$0")/env.sh"
SOURCES="${FUSIONPLAY_PERF_SOURCE_ROOT:-$REPO/macos/Sources}"
LABEL="${FUSIONPLAY_PERF_LABEL:-current}"
OUTPUT="$PROJECT/artifacts/lyrics-resize-performance/$LABEL"
mkdir -p "$PROJECT/build" "$PROJECT/cache/swift" "$OUTPUT"
xcrun swiftc -O -D FUSIONPLAY_REFLOW_BENCHMARK -swift-version 5 -parse-as-library -target arm64-apple-macosx14.0 \
  -module-cache-path "$PROJECT/cache/swift" -framework SwiftUI -framework AppKit \
  "$SOURCES/LyricsTypography.swift" "$SOURCES/AppTypography.swift" "$SOURCES/AppLanguage.swift" \
  "$SOURCES/LyricsDocument.swift" "$SOURCES/LyricsFollowPosition.swift" "$SOURCES/LyricsDisplayMode.swift" \
  "$SOURCES/LyricsStaggerMotion.swift" "$SOURCES/LyricsWordLayout.swift" "$SOURCES/NativeLyricsReflowText.swift" \
  "$SOURCES/LyricsReflowText.swift" "$SOURCES/LyricsViewportAnchor.swift" "$SOURCES/LyricsView.swift" \
  "$REPO/macos/Tests/LyricsResizePerformance.swift" -o "$PROJECT/build/lyrics-resize-performance-$LABEL"
for mode in native viewport compact; do
  for scenario in unchanged reflow; do
    "$PROJECT/build/lyrics-resize-performance-$LABEL" "$mode" "$scenario" "$OUTPUT/$mode-$scenario.json"
  done
done
