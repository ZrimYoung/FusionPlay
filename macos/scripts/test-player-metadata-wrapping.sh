#!/bin/bash
source "$(dirname "$0")/env.sh"
mkdir -p "$PROJECT/artifacts/player-metadata-wrapping-check" "$PROJECT/tmp/metadata-wrap-home/Library/Preferences"
xcrun swiftc -swift-version 5 -parse-as-library -target arm64-apple-macosx14.0 \
  -module-cache-path "$PROJECT/cache/swift" -framework SwiftUI -framework AppKit \
  "$REPO/macos/Sources/AppTypography.swift" "$REPO/macos/Sources/PlayerTrackMetadataView.swift" \
  "$REPO/macos/Tests/PlayerMetadataWrappingSmoke.swift" -o "$PROJECT/build/player-metadata-wrapping-smoke"
CFFIXED_USER_HOME="$PROJECT/tmp/metadata-wrap-home" "$PROJECT/build/player-metadata-wrapping-smoke" "$PROJECT/artifacts/player-metadata-wrapping-check"
