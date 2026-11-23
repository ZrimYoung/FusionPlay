#!/bin/bash
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PROJECT="${FUSIONPLAY_PROJECT_ROOT:-$(dirname "$REPO")}"
CHECK_ROOT="$(mktemp -d /tmp/fusionplay-artwork-blur-check.XXXXXX)"
mkdir -p "$CHECK_ROOT/home/Library/Preferences"
xcrun swiftc -D FUSIONPLAY_UI_CHECKS -swift-version 5 -parse-as-library -target arm64-apple-macosx14.0 \
  -module-cache-path "$PROJECT/cache/swift" -framework SwiftUI -framework AppKit -framework CoreImage \
  "$REPO/macos/Sources/PlayerArtworkBackdrop.swift" "$REPO/macos/Tests/CachedArtworkBlurSmoke.swift" \
  -o "$CHECK_ROOT/cached-artwork-blur-smoke"
CFFIXED_USER_HOME="$CHECK_ROOT/home" "$CHECK_ROOT/cached-artwork-blur-smoke"
