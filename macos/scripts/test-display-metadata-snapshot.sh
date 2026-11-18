#!/bin/bash
source "$(dirname "$0")/env.sh"
GENERATED="$PROJECT/build/bindings"
SOURCE_LIBRARY="$PROJECT/artifacts/FusionPlay Mac.app/Contents/Frameworks/libfusionplay_host.dylib"
CHECK_DIR="$(mktemp -d "$PROJECT/tmp/display-metadata-snapshot.XXXXXX")"
trap 'rm -rf "$CHECK_DIR"' EXIT
cp "$SOURCE_LIBRARY" "$CHECK_DIR/libfusionplay_host.dylib"
codesign --force --sign - "$CHECK_DIR/libfusionplay_host.dylib"
LIBRARY_DIR="$CHECK_DIR"
xcrun swiftc -swift-version 5 -parse-as-library -target arm64-apple-macosx14.0 \
  -module-cache-path "$CHECK_DIR/modules" \
  -I "$GENERATED" -Xcc "-fmodule-map-file=$GENERATED/FusionPlayBridgeFFI.modulemap" \
  -L "$LIBRARY_DIR" -lfusionplay_host -Xlinker -rpath -Xlinker "$LIBRARY_DIR" \
  "$GENERATED/FusionPlayBridge.swift" \
  "$REPO/macos/Sources/LyricsDocument.swift" "$REPO/macos/Sources/DisplayMetadataResolver.swift" \
  "$REPO/macos/Sources/SnapshotDisplayMetadata.swift" \
  "$REPO/macos/Tests/DisplayMetadataSnapshotSmoke.swift" -o "$CHECK_DIR/check"
codesign --force --sign - "$CHECK_DIR/check"
"$CHECK_DIR/check"
