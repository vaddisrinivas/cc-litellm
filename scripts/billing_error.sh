#!/usr/bin/env bash
# Fired by Claude Code's StopFailure hook on billing/limit errors.
# Patches Claude settings.json, then restarts Claude so only Claude Code uses
# the local proxy. It intentionally does not set launchctl or shell env vars.

set -euo pipefail

CONFIG_HOME="${CC_LITELLM_HOME:-$HOME/.config/cc-litellm}"
SETTINGS="$HOME/.claude/settings.json"
HISTORY="$CONFIG_HOME/history.log"
mkdir -p "$CONFIG_HOME"

log() { printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$HISTORY"; }

MASTER_KEY="sk-proxy-local"
if [[ -f "$CONFIG_HOME/.env" ]]; then
  val=$(grep '^LITELLM_MASTER_KEY=' "$CONFIG_HOME/.env" | cut -d= -f2 | tr -d '"')
  MASTER_KEY="${val:-sk-proxy-local}"
fi

log "billing_error fired"

# Show approval dialog
RESULT=$(osascript -e '
display dialog "Claude Code usage limit reached.\n\nSwitch to Azure AI (gpt-54-nano) via LiteLLM proxy?\n\nClaude will restart automatically." buttons {"Cancel", "Switch to Azure"} default button "Switch to Azure" cancel button "Cancel" with title "Claude Code — Limit Reached" with icon caution giving up after 120
' 2>&1)

if [[ $? -ne 0 ]] || [[ "$RESULT" == *"gave up:true"* ]]; then
  log "cancelled — staying on Anthropic"
  osascript -e 'display notification "Staying on Anthropic. Restart Claude Code when limits reset." with title "Claude Code" sound name "Pop"'
  exit 0
fi

log "approved — switching Claude Code to local proxy"

# 1. Patch settings.json — set proxy env + disable plugins/hooks that can
# interfere while Claude is in fallback mode. Save state for revert.
python3 - "$SETTINGS" "$MASTER_KEY" "$CONFIG_HOME" <<'EOF'
import sys, json
from pathlib import Path
path, key, config_home = sys.argv[1], sys.argv[2], sys.argv[3]
settings_path = Path(path)
if settings_path.exists():
    cfg = json.loads(settings_path.read_text())
else:
    cfg = {}

# Set proxy env
env = cfg.setdefault("env", {})
env.pop("ANTHROPIC_API_KEY", None)
env.update({
    "ANTHROPIC_BASE_URL": "http://localhost:4000",
    "ANTHROPIC_AUTH_TOKEN": key
})

# Save current plugin state, then disable all except cc-litellm
plugins = cfg.get("enabledPlugins", {})
if isinstance(plugins, dict):
    backup_path = Path(config_home) / "plugins_backup.json"
    if not backup_path.exists():
        backup_path.write_text(json.dumps(plugins, indent=2) + "\n")
    for name in plugins:
        if "cc-litellm" not in name:
            plugins[name] = False

# Save current hooks state, then disable non-cc-litellm hooks
hooks = cfg.get("hooks", {})
if isinstance(hooks, dict):
    def is_litellm(entry):
        if not isinstance(entry, dict):
            return False
        return any(
            "session_start.sh" in (h.get("command", "") or "")
            or "billing_error.sh" in (h.get("command", "") or "")
            for h in entry.get("hooks", [])
            if isinstance(h, dict)
        )

    hooks_backup = {}
    for event, entries in hooks.items():
        if not isinstance(entries, list):
            continue
        hooks_backup[event] = [entry for entry in entries if not is_litellm(entry)]
        hooks[event] = [entry for entry in entries if is_litellm(entry)]

    backup_path = Path(config_home) / "hooks_backup.json"
    if not backup_path.exists():
        backup_path.write_text(json.dumps(hooks_backup, indent=2) + "\n")

with settings_path.open("w") as f:
    json.dump(cfg, f, indent=2)
    f.write("\n")
EOF
log "settings.json patched (proxy env + plugins disabled)"

# 2. Kill + relaunch Claude (new process loads updated settings.json)
log "killing Claude.app..."
osascript -e 'tell application "Claude" to quit' 2>/dev/null || true
sleep 1
pkill -f "Claude.app/Contents/MacOS" 2>/dev/null || true
sleep 1

log "relaunching Claude.app..."
open -a "Claude"

# 3. Send "continue" after app opens
sleep 4
osascript <<'APPLESCRIPT'
tell application "Claude" to activate
delay 1
tell application "System Events"
  tell process "Claude"
    keystroke "continue"
    key code 36
  end tell
end tell
APPLESCRIPT

log "done — Claude Code proxy=http://localhost:4000"
