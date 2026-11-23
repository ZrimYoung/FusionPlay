#!/bin/bash
source "$(dirname "$0")/env.sh"
CHECK="$PROJECT/tmp/lyrics-stagger-settings-check.app"
mkdir -p "$CHECK/Contents/MacOS" "$CHECK/Contents/Resources" "$PROJECT/tmp/lyrics-stagger-settings-check-state"
cat > "$CHECK/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>tech.zrim.fusionplay.stagger-settings-check</string>
<key>CFBundleName</key><string>FusionPlay Stagger Settings Check</string>
<key>CFBundleExecutable</key><string>StaggerSettingsCheck</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSUIElement</key><true/>
<key>LSMinimumSystemVersion</key><string>14.0</string>
</dict></plist>
PLIST
cp -R "$REPO/macos/Resources/"*.lproj "$CHECK/Contents/Resources/"
xcrun swiftc -swift-version 5 -parse-as-library -target arm64-apple-macosx14.0 \
  -module-cache-path "$PROJECT/cache/swift" -framework SwiftUI -framework AppKit \
  "$REPO/macos/Sources/AppTypography.swift" "$REPO/macos/Sources/AppLanguage.swift" \
  "$REPO/macos/Sources/LyricsTypography.swift" "$REPO/macos/Sources/LyricsStaggerMotion.swift" \
  "$REPO/macos/Sources/LyricsStaggerSettingsSection.swift" \
  "$REPO/macos/Tests/LyricsStaggerSettingsSmoke.swift" \
  -o "$CHECK/Contents/MacOS/StaggerSettingsCheck"
CFFIXED_USER_HOME="$PROJECT/tmp/lyrics-stagger-settings-check-state" \
  "$CHECK/Contents/MacOS/StaggerSettingsCheck"
