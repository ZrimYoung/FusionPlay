#!/bin/bash
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PROJECT="${FUSIONPLAY_PROJECT_ROOT:-$(dirname "$REPO")}"
SNAPSHOT="${FUSIONPLAY_RAPID_SNAPSHOT:-}"
LABEL="${FUSIONPLAY_RAPID_LABEL:-current}"
WORK="$(mktemp -d /tmp/fusionplay-rapid-resize-check.XXXXXX)"
CHECK="$WORK/PlayerRapidResizeCheck.app"
OUTPUT="${FUSIONPLAY_RAPID_OUTPUT:-$PROJECT/artifacts/player-rapid-resize-check/$LABEL}"
mkdir -p "$CHECK/Contents/MacOS" "$CHECK/Contents/Frameworks" "$CHECK/Contents/Resources" "$WORK/home/Library/Preferences" "$OUTPUT"
rm -f "$OUTPUT/results.json" "$OUTPUT/run.log"
if [[ -n "$SNAPSHOT" ]]; then
  cp -R "$SNAPSHOT/Sources" "$WORK/Sources"
  cp -R "$SNAPSHOT/bindings" "$WORK/bindings"
  cp "$SNAPSHOT/libfusionplay_host.dylib" "$CHECK/Contents/Frameworks/"
  cp "$SNAPSHOT/Info.plist" "$CHECK/Contents/Info.plist"
  cp -R "$SNAPSHOT/Resources/"*.lproj "$CHECK/Contents/Resources/"
else
  cp -R "$REPO/macos/Sources" "$WORK/Sources"
  cp -R "$PROJECT/build/bindings" "$WORK/bindings"
  cp "$PROJECT/artifacts/FusionPlay Mac.app/Contents/Frameworks/libfusionplay_host.dylib" "$CHECK/Contents/Frameworks/"
  cp "$REPO/macos/Info.plist" "$CHECK/Contents/Info.plist"
  cp -R "$REPO/macos/Resources/"*.lproj "$CHECK/Contents/Resources/"
fi
cp "$REPO/macos/Tests/PlayerRapidResizeSmoke.swift" "$WORK/PlayerRapidResizeSmoke.swift"
# The before snapshot predates the read-only diagnostic getter; inject only
# that same getter in the private build, leaving all runtime behavior intact.
python3 - "$WORK/Sources/PlayerResponsiveMotion.swift" "$WORK" "$OUTPUT/source-manifest.json" <<'PY'
import hashlib,json,pathlib,sys
p=pathlib.Path(sys.argv[1]); s=p.read_text()
if 'var targetPoseForCheck:' not in s:
    marker='    var hasScheduledTimer: Bool { timer != nil }'
    assert marker in s
    s=s.replace(marker,marker+'\n#if FUSIONPLAY_UI_CHECKS\n    var targetPoseForCheck: PlayerCanvasPose? { template }\n#endif',1)
    p.write_text(s)
root=pathlib.Path(sys.argv[2]); files={}
for directory in ['Sources','bindings']:
    for source in sorted((root/directory).rglob('*')):
        if source.is_file(): files[str(source.relative_to(root))]=hashlib.sha256(source.read_bytes()).hexdigest()
files['fixture']=hashlib.sha256((root/'PlayerRapidResizeSmoke.swift').read_bytes()).hexdigest()
pathlib.Path(sys.argv[3]).write_text(json.dumps(files,sort_keys=True,indent=2))
PY
/usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier tech.zrim.fusionplay.rapid-resize-check' "$CHECK/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleExecutable PlayerRapidResizeCheck' "$CHECK/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :LSUIElement true' "$CHECK/Contents/Info.plist"
GENERATED="$WORK/bindings"
xcrun swiftc -D FUSIONPLAY_UI_CHECKS -swift-version 5 -parse-as-library -target arm64-apple-macosx14.0 \
  -module-cache-path "$PROJECT/cache/swift" -I "$GENERATED" -Xcc "-fmodule-map-file=$GENERATED/FusionPlayBridgeFFI.modulemap" \
  -L "$CHECK/Contents/Frameworks" -lfusionplay_host -Xlinker -rpath -Xlinker '@executable_path/../Frameworks' \
  -framework SwiftUI -framework AppKit -framework MediaPlayer -framework ScreenCaptureKit -framework CoreImage \
  "$GENERATED/FusionPlayBridge.swift" "$WORK"/Sources/*.swift "$WORK/PlayerRapidResizeSmoke.swift" \
  -o "$CHECK/Contents/MacOS/PlayerRapidResizeCheck"
codesign --force --sign - "$CHECK/Contents/Frameworks/libfusionplay_host.dylib"
codesign --force --sign - "$CHECK"
codesign --verify --deep --strict "$CHECK"
CFFIXED_USER_HOME="$WORK/home" FUSIONPLAY_RAPID_ROOT="$WORK" FUSIONPLAY_RAPID_MODE="$LABEL" FUSIONPLAY_RAPID_OUTPUT="$OUTPUT/results.json" \
  "$CHECK/Contents/MacOS/PlayerRapidResizeCheck" 2>&1 | tee "$OUTPUT/run.log"
