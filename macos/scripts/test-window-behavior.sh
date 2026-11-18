#!/bin/bash
source "$(dirname "$0")/env.sh"
xcrun swiftc -swift-version 5 -parse-as-library -target arm64-apple-macosx14.0 \
  -module-cache-path "$PROJECT/cache/swift" -framework SwiftUI -framework AppKit \
  "$REPO/macos/Sources/PlayerWindowBehavior.swift" "$REPO/macos/Tests/WindowBehaviorSmoke.swift" \
  -o "$PROJECT/build/window-behavior-smoke"
"$PROJECT/build/window-behavior-smoke"
