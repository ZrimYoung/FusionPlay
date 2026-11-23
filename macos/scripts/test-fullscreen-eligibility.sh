#!/bin/bash
source "$(dirname "$0")/env.sh"
CHECK="$PROJECT/tmp/fullscreen-eligibility-check.app"
RESULT="$PROJECT/artifacts/fullscreen-eligibility-check"
mkdir -p "$CHECK/Contents/MacOS" "$RESULT" "$PROJECT/tmp/fullscreen-eligibility-check-state"
cat > "$CHECK/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>tech.zrim.fusionplay.fullscreen-eligibility-check</string>
<key>CFBundleName</key><string>FusionPlay Fullscreen Eligibility Check</string>
<key>CFBundleExecutable</key><string>FullscreenEligibilityCheck</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSUIElement</key><true/>
<key>LSMinimumSystemVersion</key><string>14.0</string>
</dict></plist>
PLIST
xcrun swiftc -swift-version 5 -parse-as-library -target arm64-apple-macosx14.0 \
  -module-cache-path "$PROJECT/cache/swift" -framework SwiftUI -framework AppKit \
  "$REPO/macos/Sources/NarrowPlayerLayout.swift" "$REPO/macos/Sources/PlayerWindowBehavior.swift" "$REPO/macos/Tests/PlayerFullScreenEligibilitySmoke.swift" \
  -o "$CHECK/Contents/MacOS/FullscreenEligibilityCheck"
CFFIXED_USER_HOME="$PROJECT/tmp/fullscreen-eligibility-check-state" \
  FUSIONPLAY_FULLSCREEN_CHECK_RESULT="$RESULT/result.json" \
  "$CHECK/Contents/MacOS/FullscreenEligibilityCheck"
