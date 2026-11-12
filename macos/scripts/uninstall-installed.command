#!/bin/bash
set -euo pipefail
APP="/Applications/FusionPlay Mac.app"
DATA="$HOME/Library/Application Support/FusionPlay"
if [[ -L "$DATA" || ! -f "$DATA/.installed-fusionplay" || "$(cat "$DATA/.installed-fusionplay")" != "fusionplay-installed-v1" ]]; then
  echo '未找到安装标记，未删除任何内容。'; exit 1
fi
if [[ -e "$APP" ]] && { [[ -L "$APP" ]] || [[ "$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$APP/Contents/Info.plist")" != 'tech.zrim.fusionplay.mac' ]]; }; then
  echo '应用路径不匹配，未删除任何内容。'; exit 1
fi
printf '将删除应用、设置、设备身份、日志和本应用偏好：\n%s\n%s\n源码及外置盘构建缓存保留。\n' "$APP" "$DATA"
read -r -p '输入 DELETE 确认卸载：' answer
[[ "$answer" == DELETE ]] || exit 0
osascript -e 'tell application id "tech.zrim.fusionplay.mac" to quit' 2>/dev/null || true
for ((i=0;i<40;i++)); do
  pgrep -x FusionPlayMac >/dev/null || break
  sleep 0.25
done
if pgrep -x FusionPlayMac >/dev/null; then
  echo '应用仍在运行，未删除文件。'; exit 1
fi
defaults delete tech.zrim.fusionplay.mac 2>/dev/null || true
rm -rf -- "$APP" "$DATA" "$HOME/Library/Saved Application State/tech.zrim.fusionplay.mac.savedState" "$HOME/Library/Caches/tech.zrim.fusionplay.mac"
echo '卸载完成。系统维护的隐私授权记录不在清理范围内。'
