#!/bin/bash
source "$(dirname "$0")/env.sh"
mkdir -p "$PROJECT/tmp/appearance-group-home/Library/Preferences"
xcrun swiftc -swift-version 5 -parse-as-library -target arm64-apple-macosx14.0 \
  -module-cache-path "$PROJECT/cache/swift" -framework SwiftUI -framework AppKit \
  "$REPO/macos/Sources/AppLanguage.swift" "$REPO/macos/Sources/AppTypography.swift" \
  "$REPO/macos/Sources/NarrowPlayerLayout.swift" "$REPO/macos/Sources/PlayerLayoutAppearancePreferences.swift" \
  "$REPO/macos/Sources/PlayerAppearance.swift" "$REPO/macos/Sources/LyricsDisplayMode.swift" \
  "$REPO/macos/Sources/LyricsTypography.swift" "$REPO/macos/Sources/LyricsStaggerMotion.swift" \
  "$REPO/macos/Sources/LyricsStaggerSettingsSection.swift" "$REPO/macos/Sources/MenuPanelAppearance.swift" \
  "$REPO/macos/Sources/SettingsDetailPanel.swift" "$REPO/macos/Sources/FontSettingsSection.swift" \
  "$REPO/macos/Sources/AppearanceSettingsPage.swift" "$REPO/macos/Tests/AppearanceGroupingSmoke.swift" \
  -o "$PROJECT/build/appearance-grouping-smoke"
CFFIXED_USER_HOME="$PROJECT/tmp/appearance-group-home" "$PROJECT/build/appearance-grouping-smoke"
