#!/bin/bash
source "$(dirname "$0")/env.sh"
cd "$REPO"
CHECK="$PROJECT/tmp/player-lifecycle-check.app"
CHECK_MODE="${1:-all}"
CHECK_SOURCES="${FUSIONPLAY_LIFECYCLE_SOURCES:-$REPO/macos/Sources}"
CHECK_INFO="${FUSIONPLAY_LIFECYCLE_INFO:-$REPO/macos/Info.plist}"
CHECK_LABEL="${FUSIONPLAY_LIFECYCLE_RUN_LABEL:-current}"
RESULT="$PROJECT/artifacts/player-lifecycle-check-$CHECK_LABEL-$CHECK_MODE"
mkdir -p "$CHECK/Contents/MacOS" "$CHECK/Contents/Resources" "$PROJECT/tmp/player-lifecycle-check-state" "$RESULT"
cp "$CHECK_INFO" "$CHECK/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier tech.zrim.fusionplay.player-lifecycle-check' "$CHECK/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleExecutable PlayerLifecycleCheck' "$CHECK/Contents/Info.plist"
cp -R "$REPO/macos/Resources/"*.lproj "$CHECK/Contents/Resources/"
shasum -a 256 "$CHECK_SOURCES/FusionPlayApp.swift" "$CHECK_SOURCES/PlayerWindowBehavior.swift" "$CHECK_SOURCES/ReceiverModel.swift" > "$RESULT/source-sha256.txt"
GENERATED="$PROJECT/build/bindings"
xcrun swiftc -D FUSIONPLAY_UI_CHECKS -swift-version 5 -parse-as-library -target arm64-apple-macosx14.0 \
  -module-cache-path "$PROJECT/cache/swift" -I "$GENERATED" -Xcc "-fmodule-map-file=$GENERATED/FusionPlayBridgeFFI.modulemap" \
  -L "$PROJECT/artifacts/FusionPlay Mac.app/Contents/Frameworks" -lfusionplay_host \
  -Xlinker -rpath -Xlinker "$PROJECT/artifacts/FusionPlay Mac.app/Contents/Frameworks" \
  -framework SwiftUI -framework AppKit -framework MediaPlayer \
  "$GENERATED/FusionPlayBridge.swift" "$CHECK_SOURCES"/*.swift "$REPO/macos/Tests/PlayerWindowLifecycleSmoke.swift" \
  -o "$CHECK/Contents/MacOS/PlayerLifecycleCheck"
CFFIXED_USER_HOME="$PROJECT/tmp/player-lifecycle-check-state" \
  FUSIONPLAY_LIFECYCLE_ROOT="$RESULT" FUSIONPLAY_LIFECYCLE_MODE="$CHECK_MODE" \
  FUSIONPLAY_LIFECYCLE_STRESS_SECONDS="${FUSIONPLAY_LIFECYCLE_STRESS_SECONDS:-0}" \
  python3 - "$CHECK/Contents/MacOS/PlayerLifecycleCheck" "$RESULT" <<'PY'
import json,os,subprocess,sys,time
from pathlib import Path
exe,result=sys.argv[1],Path(sys.argv[2])
stress_seconds=float(os.environ.get('FUSIONPLAY_LIFECYCLE_STRESS_SECONDS','0'))
if not __import__('math').isfinite(stress_seconds) or stress_seconds < 0:
 raise SystemExit('Stress duration must be a finite nonnegative number')
timeout_seconds=max(60,stress_seconds+35)
started=time.monotonic()
with (result/'process.log').open('w') as log:
 process=subprocess.Popen([exe],stdout=log,stderr=subprocess.STDOUT,env=os.environ.copy())
 timed_out=False
 try: code=process.wait(timeout=timeout_seconds)
 except subprocess.TimeoutExpired:
  timed_out=True;process.kill();code=process.wait()
summary={'exitCode':code,'timedOut':timed_out,'elapsedSeconds':time.monotonic()-started,'stressSecondsRequested':stress_seconds,'timeoutSeconds':timeout_seconds}
(result/'process-result.json').write_text(json.dumps(summary,indent=2)+'\n')
print(json.dumps(summary))
print('Lifecycle evidence:',result)
sys.exit(124 if timed_out else (code if code>=0 else 128-code))
PY
