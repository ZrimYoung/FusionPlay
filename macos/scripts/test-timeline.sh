#!/bin/bash
source "$(dirname "$0")/env.sh"
xcrun swiftc -swift-version 5 -parse-as-library -module-cache-path "$PROJECT/cache/swift" \
  "$REPO/macos/Sources/PlaybackTimeline.swift" "$REPO/macos/Tests/PlaybackTimelineSmoke.swift" \
  -o "$PROJECT/build/timeline-smoke"
"$PROJECT/build/timeline-smoke"
