#!/bin/bash
# TimeLog installer — automatic Claude Code time tracking + review UI + Tempo submission.
#
#   git clone <repo-url> && cd TimeLog && bash install.sh
#
# What it does (all idempotent, re-run after every git pull):
#   1. Copies runtime (hooks/CLI/server/UI) to ~/.claude/timelog/app/
#   2. Copies skills to ~/.claude/commands/ (user-level — all projects)
#   3. Merges tracking hooks into ~/.claude/settings.json
#   4. Installs a launchd agent serving the review UI on http://localhost:8377
#   5. Builds ~/Applications/Timelog.app (dock launcher) with icon
#   6. Runs the test suite
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
APP="$HOME/.claude/timelog/app"

echo "== Checking dependencies"
for dep in jq python3 curl; do
  command -v "$dep" >/dev/null || { echo "Missing: $dep (brew install $dep)"; exit 1; }
done

echo "== Installing runtime to $APP"
mkdir -p "$APP" "$HOME/.claude/timelog/daily" "$HOME/.claude/timelog/sessions" "$HOME/.claude/timelog/overrides"
# installed flat: the server resolves the CLI relative to its own location
cp "$ROOT"/hooks/* "$ROOT"/cli/* "$ROOT"/ui/* "$ROOT"/tests/* "$APP/"
chmod +x "$APP"/*.sh

echo "== Installing skills to ~/.claude/commands"
mkdir -p "$HOME/.claude/commands"
cp "$ROOT"/skills/* "$HOME/.claude/commands/"

echo "== Writing config (jira base url)"
CONFIG="$HOME/.claude/timelog/config.json"
[[ -f "$CONFIG" ]] || echo '{"jira_base": "https://sportabler.atlassian.net"}' > "$CONFIG"

echo "== Merging hooks into ~/.claude/settings.json"
python3 - << 'PYEOF'
import json, os

path = os.path.expanduser("~/.claude/settings.json")
settings = json.load(open(path)) if os.path.exists(path) else {}
hooks = settings.setdefault("hooks", {})
APP = os.path.expanduser("~/.claude/timelog/app").replace(os.path.expanduser("~"), "$HOME", 1)

def group(command, matcher=None, timeout=None):
    h = {"type": "command", "command": command}
    if timeout:
        h["timeout"] = timeout
    g = {"hooks": [h]}
    if matcher:
        g["matcher"] = matcher
    return g

wanted = {
    "SessionStart":     [group(f"bash {APP}/session-start.sh")],
    "UserPromptSubmit": [group(f"bash {APP}/track-prompt.sh")],
    "PostToolUse":      [group(f"bash {APP}/track-edit.sh", matcher="Write|Edit"),
                         group(f"bash {APP}/track-activity.sh")],
    "Stop":             [group(f"bash {APP}/track-activity.sh")],
    "SessionEnd":       [group(f"python3 {APP}/session-end.sh", timeout=120)],
}

for event, groups in wanted.items():
    current = hooks.get(event, [])
    # strip any previous timelog entries, keep everything else
    current = [g for g in current
               if not any("timelog" in h.get("command", "") for h in g.get("hooks", []))]
    hooks[event] = current + groups

json.dump(settings, open(path, "w"), indent=2)
print("   hooks merged")
PYEOF

echo "== Installing launchd agent (UI server on :8377)"
PLIST="$HOME/Library/LaunchAgents/io.abler.timelog-server.plist"
cat > "$PLIST" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>io.abler.timelog-server</string>
  <key>ProgramArguments</key>
  <array>
    <string>/usr/bin/python3</string>
    <string>$APP/timelog-server.py</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>StandardErrorPath</key>
  <string>/tmp/timelog-server.err</string>
</dict>
</plist>
EOF
launchctl bootout "gui/$(id -u)/io.abler.timelog-server" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"

echo "== Building Timelog.app (dock launcher)"
ICON_TMP=$(mktemp -d)
qlmanage -t -s 1024 -o "$ICON_TMP" "$APP/timelog-logo.svg" >/dev/null 2>&1
PNG="$ICON_TMP/timelog-logo.svg.png"
if [[ -f "$PNG" ]]; then
  mkdir -p "$ICON_TMP/Timelog.iconset"
  for s in 16 32 64 128 256 512; do
    sips -z $s $s "$PNG" --out "$ICON_TMP/Timelog.iconset/icon_${s}x${s}.png" >/dev/null
    sips -z $((s*2)) $((s*2)) "$PNG" --out "$ICON_TMP/Timelog.iconset/icon_${s}x${s}@2x.png" >/dev/null
  done
  iconutil -c icns "$ICON_TMP/Timelog.iconset" -o "$ICON_TMP/Timelog.icns"
fi
mkdir -p "$HOME/Applications"
rm -rf "$HOME/Applications/Timelog.app"
osacompile -o "$HOME/Applications/Timelog.app" -e 'do shell script "pgrep -f timelog-server.py >/dev/null || launchctl kickstart gui/$(id -u)/io.abler.timelog-server"
open location "http://localhost:8377"' 2>/dev/null
[[ -f "$ICON_TMP/Timelog.icns" ]] && cp "$ICON_TMP/Timelog.icns" "$HOME/Applications/Timelog.app/Contents/Resources/applet.icns"
rm -rf "$ICON_TMP"

echo "== Running test suite"
python3 "$APP/test-timelog.sh" >/dev/null && echo "   tests pass"

sleep 1
curl -s -o /dev/null -w "== Server check: HTTP %{http_code}\n" http://localhost:8377/api/days || true

cat << 'EOF'

Done. Remaining manual steps:
 1. Tokens:  open http://localhost:8377 → ⚙️ Tokens & settings → paste
             Jira API token (id.atlassian.com/manage-profile/security/api-tokens)
             and Tempo token (Tempo → Settings → API Integration).
 2. Dock:    drag ~/Applications/Timelog.app to the Dock, or open the URL in
             Safari → File → Add to Dock.
 3. Claude:  /submit-times' MCP path needs Tempo + Atlassian connectors (/mcp).
EOF
