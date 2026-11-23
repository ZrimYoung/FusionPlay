#!/bin/bash
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PROJECT="${FUSIONPLAY_PROJECT_ROOT:-$(dirname "$REPO")}"
CHECK_ROOT="$(mktemp -d /tmp/fusionplay-lyrics-bleed.XXXXXX)"
SOURCES=(NarrowPlayerLayout LyricsDisplayMode PlayerPresentationPolicy ExpandedLyricsLayout PlayerResponsiveLayout PlayerResponsiveMotion)
INPUTS=()
for source in "${SOURCES[@]}"; do
  cp "$REPO/macos/Sources/$source.swift" "$CHECK_ROOT/$source.swift"
  INPUTS+=("$CHECK_ROOT/$source.swift")
done
cp "$REPO/macos/Tests/PlayerLyricsBleedSmoke.swift" "$CHECK_ROOT/PlayerLyricsBleedSmoke.swift"
xcrun swiftc -D FUSIONPLAY_UI_CHECKS -swift-version 5 -parse-as-library \
  -target "$(uname -m)-apple-macosx14.0" -module-cache-path "$PROJECT/cache/swift" \
  -framework SwiftUI -framework AppKit -framework CoreImage "${INPUTS[@]}" "$CHECK_ROOT/PlayerLyricsBleedSmoke.swift" \
  -o "$CHECK_ROOT/PlayerLyricsBleedCheck"
"$CHECK_ROOT/PlayerLyricsBleedCheck"
