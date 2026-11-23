#!/bin/bash
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PROJECT="${FUSIONPLAY_PROJECT_ROOT:-$(dirname "$REPO")}"
LABEL="${FUSIONPLAY_CANVAS_PERF_LABEL:-current}"
WORK="$(mktemp -d /tmp/fusionplay-canvas-performance.XXXXXX)"
CHECK="$WORK/PlayerCanvasPerformanceCheck.app"
OUTPUT="${FUSIONPLAY_CANVAS_PERF_OUTPUT_DIR:-/tmp/fusionplay-player-canvas-performance/$LABEL}"
SNAPSHOT="${FUSIONPLAY_CANVAS_PERF_SNAPSHOT:-}"
if [[ -n "$SNAPSHOT" ]]; then
  SOURCES="$SNAPSHOT/Sources"
  BINDINGS="$SNAPSHOT/bindings"
  LIBRARY="$SNAPSHOT/libfusionplay_host.dylib"
else
  SOURCES="$REPO/macos/Sources"
  BINDINGS="${FUSIONPLAY_CANVAS_PERF_BINDINGS:-$PROJECT/build/bindings}"
  LIBRARY="${FUSIONPLAY_CANVAS_PERF_LIBRARY:-$PROJECT/artifacts/FusionPlay Mac.app/Contents/Frameworks/libfusionplay_host.dylib}"
fi
mkdir -p "$CHECK/Contents/MacOS" "$CHECK/Contents/Resources" "$CHECK/Contents/Frameworks" "$WORK/home/Library/Preferences" "$WORK/cache" "$OUTPUT"
rm -f "$OUTPUT/results.json" "$OUTPUT/run.log"
cp -R "$SOURCES" "$WORK/Sources"
cp -R "$BINDINGS" "$WORK/bindings"
cp "$LIBRARY" "$CHECK/Contents/Frameworks/libfusionplay_host.dylib"
cp "$REPO/macos/Tests/PlayerCanvasPerformanceSmoke.swift" "$WORK/PlayerCanvasPerformanceSmoke.swift"
cp -R "$REPO/macos/Resources/"*.lproj "$CHECK/Contents/Resources/"
cp "$REPO/macos/Info.plist" "$CHECK/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier tech.zrim.fusionplay.canvas-performance-check' "$CHECK/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleExecutable PlayerCanvasPerformanceCheck' "$CHECK/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :LSUIElement true' "$CHECK/Contents/Info.plist"
python3 - "$WORK" "$LABEL" "$OUTPUT/source-manifest.json" <<'PY'
import hashlib,json,pathlib,sys
root=pathlib.Path(sys.argv[1]); files={}
for directory in ['Sources','bindings']:
    for path in sorted((root/directory).rglob('*')):
        if path.is_file(): files[str(path.relative_to(root))]=hashlib.sha256(path.read_bytes()).hexdigest()
for relative in ['PlayerCanvasPerformanceSmoke.swift','PlayerCanvasPerformanceCheck.app/Contents/Frameworks/libfusionplay_host.dylib']:
    path=root/relative; files[relative]=hashlib.sha256(path.read_bytes()).hexdigest()
combined=hashlib.sha256(json.dumps(files,sort_keys=True).encode()).hexdigest()
pathlib.Path(sys.argv[3]).write_text(json.dumps({'label':sys.argv[2],'combinedSHA256':combined,'files':files,
 'trajectory':'60ticks each:760-480-760 width triangle;760to520 spring;520 lyrics-at0/playback-at30 spring;dt=1/60',
 'compile':'-O -D FUSIONPLAY_UI_CHECKS -D FUSIONPLAY_REFLOW_BENCHMARK -target arm64-apple-macosx14.0'},sort_keys=True,indent=2))
print('Frozen measurement sources:',root,'SHA256',combined)
PY
GENERATED="$WORK/bindings"
xcrun swiftc -O -D FUSIONPLAY_UI_CHECKS -D FUSIONPLAY_REFLOW_BENCHMARK -swift-version 5 -parse-as-library -target arm64-apple-macosx14.0 \
  -module-cache-path "$WORK/cache" -I "$GENERATED" -Xcc "-fmodule-map-file=$GENERATED/FusionPlayBridgeFFI.modulemap" \
  -L "$CHECK/Contents/Frameworks" -lfusionplay_host -Xlinker -rpath -Xlinker '@executable_path/../Frameworks' \
  -framework SwiftUI -framework AppKit -framework MediaPlayer -framework ScreenCaptureKit \
  "$GENERATED/FusionPlayBridge.swift" "$WORK"/Sources/*.swift "$WORK/PlayerCanvasPerformanceSmoke.swift" \
  -o "$CHECK/Contents/MacOS/PlayerCanvasPerformanceCheck"
codesign --force --sign - "$CHECK/Contents/Frameworks/libfusionplay_host.dylib"
codesign --force --sign - "$CHECK"
codesign --verify --deep --strict "$CHECK"
RUNNER="$OUTPUT/run-isolated.sh"
{
  printf '#!/bin/bash\nset -euo pipefail\n'
  printf 'export CFFIXED_USER_HOME=%q\n' "$WORK/home"
  printf 'export FUSIONPLAY_CANVAS_PERF_ROOT=%q\n' "$WORK"
  printf 'export FUSIONPLAY_CANVAS_PERF_OUTPUT=%q\n' "$OUTPUT/results.json"
  printf 'export FUSIONPLAY_CANVAS_PERF_MANIFEST=%q\n' "$OUTPUT/source-manifest.json"
  printf '%q 2>&1 | tee %q\n' "$CHECK/Contents/MacOS/PlayerCanvasPerformanceCheck" "$OUTPUT/run.log"
} > "$RUNNER"
chmod 700 "$RUNNER"
if [[ "${FUSIONPLAY_CANVAS_PERF_COMPILE_ONLY:-0}" == 1 ]]; then
  echo "Compiled without starting measurement. Isolated runner: $RUNNER"
  exit 0
fi
bash "$RUNNER"
echo "Performance results: $OUTPUT/results.json"
