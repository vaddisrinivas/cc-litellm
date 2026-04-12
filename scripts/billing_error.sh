#!/usr/bin/env bash
# Fired by Claude Code's StopFailure hook on billing/limit errors.
# Patches settings.json, sets launchctl env, kills + relaunches Claude.

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

log "approved — switching to Azure proxy (gpt-54-nano)"

# 1. Patch settings.json — ANTHROPIC_AUTH_TOKEN is correct per official docs
#    (https://code.claude.com/docs/en/llm-gateway.md)
python3 - "$SETTINGS" "$MASTER_KEY" <<'EOF'
import sys, json
path, key = sys.argv[1], sys.argv[2]
with open(path) as f:
    cfg = json.load(f)
cfg.setdefault("env", {}).update({
    "ANTHROPIC_BASE_URL": "http://localhost:4000",
    "ANTHROPIC_AUTH_TOKEN": key
})
with open(path, "w") as f:
    json.dump(cfg, f, indent=2)
    f.write("\n")
EOF
log "settings.json patched (ANTHROPIC_BASE_URL + ANTHROPIC_AUTH_TOKEN)"

# 2. launchctl — belt-and-suspenders for GUI app env
launchctl setenv ANTHROPIC_BASE_URL "http://localhost:4000"
launchctl setenv ANTHROPIC_AUTH_TOKEN "$MASTER_KEY"
log "launchctl setenv done"

# 3. ~/.zshenv — CLI sessions
ZSHENV="$HOME/.zshenv"
grep -v 'ANTHROPIC_BASE_URL\|ANTHROPIC_AUTH_TOKEN\|ANTHROPIC_API_KEY\|# cc-litellm proxy' "$ZSHENV" 2>/dev/null > /tmp/zshenv_tmp || true
printf '\n# cc-litellm proxy\nexport ANTHROPIC_BASE_URL=http://localhost:4000\nexport ANTHROPIC_AUTH_TOKEN=%s\n' "$MASTER_KEY" >> /tmp/zshenv_tmp
mv /tmp/zshenv_tmp "$ZSHENV"
log "~/.zshenv updated"

# 4. Kill + relaunch Claude (new process loads updated settings.json)
log "killing Claude.app..."
osascript -e 'tell application "Claude" to quit' 2>/dev/null || true
sleep 1
pkill -f "Claude.app/Contents/MacOS" 2>/dev/null || true
sleep 1

log "relaunching Claude.app..."
open -a "Claude"

# 5. Send "continue" after app opens
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

log "done — proxy=http://localhost:4000 model=gpt-54-nano"
