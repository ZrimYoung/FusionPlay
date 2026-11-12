#!/bin/bash
source "$(dirname "$0")/env.sh"
cat > "$PROJECT/启动.command" <<'EOF'
#!/bin/bash
ROOT="$(cd "$(dirname "$0")" && pwd)"
if [[ -d "/Applications/FusionPlay Mac.app" ]]; then
  open "/Applications/FusionPlay Mac.app"
else
  open "$ROOT/artifacts/FusionPlay Mac.app"
fi
EOF
cat > "$PROJECT/停止.command" <<'EOF'
#!/bin/bash
osascript -e 'tell application id "tech.zrim.fusionplay.mac" to quit'
EOF
cat > "$PROJECT/清理.command" <<'EOF'
#!/bin/bash
ROOT="$(cd "$(dirname "$0")" && pwd)"
INSTALLED="$HOME/Library/Application Support/FusionPlay/卸载 FusionPlay.command"
if [[ -f "$INSTALLED" ]]; then
  /bin/bash "$INSTALLED"
else
  /usr/bin/python3 "$ROOT/source/macos/scripts/cleanup.py" --execute
fi
read -r -p "按回车关闭窗口…"
EOF
chmod 700 "$PROJECT/启动.command" "$PROJECT/停止.command" "$PROJECT/清理.command"
