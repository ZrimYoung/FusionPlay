#!/bin/bash
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PROJECT="${FUSIONPLAY_PROJECT_ROOT:-$(dirname "$REPO")}"
mkdir -p "$PROJECT/tmp" "$PROJECT/cache/swift"
CHECK_ROOT="$(mktemp -d "$PROJECT/tmp/window-aspect-minimum.XXXXXX")"
trap 'rm -rf "$CHECK_ROOT"' EXIT
SOURCES=(NarrowPlayerLayout PlayerWindowBehavior CoverLyricsResizeHandle AppLanguage)
INPUTS=()
for source in "${SOURCES[@]}"; do
  cp "$REPO/macos/Sources/$source.swift" "$CHECK_ROOT/$source.swift"
  INPUTS+=("$CHECK_ROOT/$source.swift")
done
cp "$REPO/macos/Tests/WindowAspectMinimumSmoke.swift" "$CHECK_ROOT/WindowAspectMinimumSmoke.swift"
nice -n 10 xcrun swiftc -D FUSIONPLAY_UI_CHECKS -swift-version 5 -parse-as-library -target "$(uname -m)-apple-macosx14.0" \
  -module-cache-path "$PROJECT/cache/swift" -framework SwiftUI -framework AppKit \
  "${INPUTS[@]}" "$CHECK_ROOT/WindowAspectMinimumSmoke.swift" -o "$CHECK_ROOT/WindowAspectMinimumCheck"
"$CHECK_ROOT/WindowAspectMinimumCheck"
