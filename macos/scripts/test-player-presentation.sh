#!/bin/bash
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PROJECT="${FUSIONPLAY_PROJECT_ROOT:-$(dirname "$REPO")}"
CHECK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/fusionplay-presentation.XXXXXX")"
trap 'rm -rf "$CHECK_DIR"' EXIT
xcrun swiftc -swift-version 5 -parse-as-library -target "$(uname -m)-apple-macosx14.0" \
  -module-cache-path "$CHECK_DIR/modules" \
  "$REPO/macos/Sources/NarrowPlayerLayout.swift" "$REPO/macos/Sources/LyricsDocument.swift" "$REPO/macos/Sources/PlayerCurrentLyricSummary.swift" \
  "$REPO/macos/Sources/LyricsDisplayMode.swift" "$REPO/macos/Sources/PlayerPresentationPolicy.swift" \
  "$REPO/macos/Tests/PlayerPresentationSmoke.swift" -o "$CHECK_DIR/policy-check"
"$CHECK_DIR/policy-check"
CHECK="$CHECK_DIR/PlayerPresentationCheck.app"
OUTPUT="$PROJECT/artifacts/player-presentation-check"
mkdir -p "$CHECK/Contents/MacOS" "$CHECK_DIR/home/Library/Preferences" "$OUTPUT"
cat > "$CHECK/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>tech.zrim.fusionplay.presentation-check</string>
<key>CFBundleExecutable</key><string>PlayerPresentationCheck</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSUIElement</key><true/>
</dict></plist>
PLIST
xcrun swiftc -swift-version 5 -parse-as-library -target "$(uname -m)-apple-macosx14.0" \
  -module-cache-path "$CHECK_DIR/modules" -framework AppKit -framework SwiftUI \
  "$REPO/macos/Sources/NarrowPlayerLayout.swift" "$REPO/macos/Sources/LyricsDocument.swift" "$REPO/macos/Sources/PlayerCurrentLyricSummary.swift" \
  "$REPO/macos/Sources/LyricsDisplayMode.swift" "$REPO/macos/Sources/PlayerPresentationPolicy.swift" \
  "$REPO/macos/Sources/AppTypography.swift" "$REPO/macos/Sources/PlayerTrackMetadataView.swift" \
  "$REPO/macos/Sources/PlayerPagingDragExclusion.swift" "$REPO/macos/Sources/PlayerNarrowPager.swift" "$REPO/macos/Tests/PlayerPresentationUISmoke.swift" \
  -o "$CHECK/Contents/MacOS/PlayerPresentationCheck"
CFFIXED_USER_HOME="$CHECK_DIR/home" "$CHECK/Contents/MacOS/PlayerPresentationCheck" "$OUTPUT"
