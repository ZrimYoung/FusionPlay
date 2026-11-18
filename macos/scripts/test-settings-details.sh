#!/bin/bash
source "$(dirname "$0")/env.sh"
CHECK="$PROJECT/tmp/settings-details-check.app"
mkdir -p "$CHECK/Contents/MacOS" "$CHECK/Contents/Resources" "$PROJECT/tmp/settings-details-check-state"
cat > "$CHECK/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>tech.zrim.fusionplay.settings-details-check</string>
<key>CFBundleName</key><string>FusionPlay Settings Details Check</string>
<key>CFBundleExecutable</key><string>SettingsDetailsCheck</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSUIElement</key><true/>
<key>LSMinimumSystemVersion</key><string>14.0</string>
</dict></plist>
PLIST
cp -R "$REPO/macos/Resources/"*.lproj "$CHECK/Contents/Resources/"
xcrun swiftc -D FUSIONPLAY_UI_CHECKS -swift-version 5 -parse-as-library -target arm64-apple-macosx14.0 \
  -module-cache-path "$PROJECT/cache/swift" -framework SwiftUI -framework AppKit \
  "$REPO/macos/Sources/AppTypography.swift" "$REPO/macos/Sources/AppLanguage.swift" \
  "$REPO/macos/Sources/SettingsHeaderBackdrop.swift" "$REPO/macos/Sources/SettingsDetailPanel.swift" \
  "$REPO/macos/Sources/FontSettingsSection.swift" "$REPO/macos/Tests/SettingsDetailsSmoke.swift" \
  -o "$CHECK/Contents/MacOS/SettingsDetailsCheck"
CFFIXED_USER_HOME="$PROJECT/tmp/settings-details-check-state" \
  "$CHECK/Contents/MacOS/SettingsDetailsCheck"
