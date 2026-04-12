#!/usr/bin/env bash
# Fired by Claude Code's StopFailure hook on billing/limit errors.
# Shows approval dialog — switches to Azure proxy, kills + relaunches Claude.

CONFIG_HOME="${CC_LITELLM_HOME:-$HOME/.config/cc-litellm}"
HISTORY="$CONFIG_HOME/history.log"
mkdir -p "$CONFIG_HOME"

log() { printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$HISTORY"; }

# Read master key from config, fall back to default
MASTER_KEY="sk-proxy-local"
if [[ -f "$CONFIG_HOME/.env" ]]; then
  val=$(grep '^LITELLM_MASTER_KEY=' "$CONFIG_HOME/.env" | cut -d= -f2 | tr -d '"')
  MASTER_KEY="${val:-sk-proxy-local}"
fi

log "billing_error fired (hook triggered)"

# Show approval dialog
RESULT=$(osascript -e '
display dialog "Claude Code usage limit reached.\n\nSwitch to Azure AI (gpt-54-nano) via LiteLLM proxy?\n\nClaude will restart automatically." buttons {"Cancel", "Switch to Azure"} default button "Switch to Azure" cancel button "Cancel" with title "Claude Code — Limit Reached" with icon caution giving up after 120
' 2>&1)

if [[ $? -ne 0 ]] || [[ "$RESULT" == *"gave up:true"* ]]; then
  log "user cancelled or timed out — staying on Anthropic"
  osascript -e 'display notification "Staying on Anthropic. Restart Claude Code when limits reset." with title "Claude Code" sound name "Pop"'
  exit 0
fi

log "user approved — switching to Azure proxy"

# 1. Set env vars at system level BEFORE relaunching
launchctl setenv ANTHROPIC_BASE_URL "http://localhost:4000"
launchctl setenv ANTHROPIC_API_KEY "$MASTER_KEY"
log "launchctl setenv done"

# 2. Update ~/.zshenv for CLI sessions
ZSHENV="$HOME/.zshenv"
grep -v 'ANTHROPIC_BASE_URL\|ANTHROPIC_API_KEY\|# cc-litellm proxy' "$ZSHENV" 2>/dev/null > /tmp/zshenv_tmp || true
printf '\n# cc-litellm proxy\nexport ANTHROPIC_BASE_URL=http://localhost:4000\nexport ANTHROPIC_API_KEY=%s\n' "$MASTER_KEY" >> /tmp/zshenv_tmp
mv /tmp/zshenv_tmp "$ZSHENV"
log "~/.zshenv updated"

# 3. Kill Claude desktop app, relaunch — new process inherits launchctl env
log "killing Claude.app..."
osascript -e 'tell application "Claude" to quit' 2>/dev/null || true
sleep 1
# Force kill if still running
pkill -f "Claude.app/Contents/MacOS" 2>/dev/null || true
sleep 1

log "relaunching Claude.app..."
open -a "Claude"

# 4. Wait for Claude to open, then send "continue" to resume session
sleep 4
osascript <<'APPLESCRIPT'
tell application "Claude" to activate
delay 1
tell application "System Events"
  tell process "Claude"
    keystroke "continue"
    key code 36  -- Return
  end tell
end tell
APPLESCRIPT

log "relaunch + continue sent — proxy=http://localhost:4000"
