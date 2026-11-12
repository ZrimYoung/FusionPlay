#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/env.sh"
cd "$REPO"
CHECK_DIR="$(mktemp -d "$TMPDIR/settings-smoke.XXXXXX")"
trap 'rm -rf -- "$CHECK_DIR"' EXIT
APP_CHECK="$CHECK_DIR/SettingsCheck.app"
mkdir -p "$APP_CHECK/Contents/MacOS" "$APP_CHECK/Contents/Resources"
cp -R macos/Resources/*.lproj "$APP_CHECK/Contents/Resources/"
cat > "$APP_CHECK/Contents/Info.plist" <<'PLIST'
<?xml version="1.0"?><plist version="1.0"><dict><key>CFBundleIdentifier</key><string>tech.zrim.fusionplay.settings-check</string><key>CFBundleExecutable</key><string>SettingsCheck</string></dict></plist>
PLIST
cat > "$CHECK_DIR/Check.swift" <<'SWIFT'
import Foundation
@main struct Check {
 static func main() throws {
  UserDefaults.standard.setVolatileDomain(["appLanguage":"en"], forName: UserDefaults.argumentDomain)
  precondition(L("同步微调") == "Sync Adjustment")
  precondition(L("高级") == "Advanced")
  UserDefaults.standard.setVolatileDomain(["appLanguage":"zh-Hans"], forName: UserDefaults.argumentDomain)
  precondition(L("同步微调") == "同步微调")
  let root = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("data")
  do {
   let receiver = try Receiver(dataDirectory: root.path)
   precondition(try receiver.syncAdjustment() == 0)
   try receiver.setSyncAdjustment(millis: -25)
   precondition(try receiver.syncAdjustment() == -25)
   try receiver.setSyncAdjustment(millis: 35)
   precondition(try receiver.syncAdjustment() == 35)
   do { try receiver.setSyncAdjustment(millis: 201); fatalError("invalid offset accepted") }
   catch {}
  }
  do {
   let restored = try Receiver(dataDirectory: root.path)
   precondition(try restored.syncAdjustment() == 35)
   try restored.setSyncAdjustment(millis: 0)
  }
  print("PASS: runtime language switch, bridge defaults/range, persisted offset and reset")
 }
}
SWIFT
# Evaluate throwing calls outside precondition's nonthrowing autoclosure.
python3 - "$CHECK_DIR/Check.swift" <<'PY'
import sys,re
from pathlib import Path
p=Path(sys.argv[1]);s=p.read_text();i=0
for match in list(re.finditer(r'precondition\(try (\w+)\.syncAdjustment\(\) == (-?\d+)\)',s))[::-1]:
 i+=1;s=s[:match.start()]+f'let checked{i} = try {match[1]}.syncAdjustment(); precondition(checked{i} == {match[2]})'+s[match.end():]
p.write_text(s)
PY
xcrun swiftc -swift-version 5 -parse-as-library -module-cache-path "$PROJECT/cache/swift" -I "$PROJECT/build/bindings" -Xcc "-fmodule-map-file=$PROJECT/build/bindings/FusionPlayBridgeFFI.modulemap" -L "$PROJECT/artifacts/FusionPlay Mac.app/Contents/Frameworks" -lfusionplay_host -Xlinker -rpath -Xlinker "$PROJECT/artifacts/FusionPlay Mac.app/Contents/Frameworks" "$PROJECT/build/bindings/FusionPlayBridge.swift" macos/Sources/AppLanguage.swift "$CHECK_DIR/Check.swift" -o "$APP_CHECK/Contents/MacOS/SettingsCheck"
"$APP_CHECK/Contents/MacOS/SettingsCheck" "$CHECK_DIR/state"
